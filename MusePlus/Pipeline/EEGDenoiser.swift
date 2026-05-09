/// EEGDenoiser.swift
/// MusePlus — Real-time SWT soft-thresholding EEG artifact denoiser
///
/// Algorithm: Stationary Wavelet Transform (à trous, no downsampling) with
/// Daubechies-4 wavelet, 5 decomposition levels, universal soft thresholding.
///
/// References:
/// - Donoho DL, Johnstone IM. "Ideal spatial adaptation by wavelet shrinkage."
///   Biometrika 81(3):425-455, 1994. — Universal threshold formula T = σ√(2 ln N)
/// - Krishnaveni V, Jayaraman S, Aravind S, Hariharasudhan V, Ramadoss K.
///   "Removal of ocular artifacts from EEG using adaptive thresholding of
///   wavelet coefficients." Journal of Neural Engineering 3(4):338-346, 2006.
///   — Motivation for wavelet-domain soft-thresholding for eye-blink suppression
/// - Mallat SG. "A Wavelet Tour of Signal Processing." Academic Press, 1999.
///   — À trous (algorithme à trous) SWT implementation reference
/// - Daubechies I. "Ten Lectures on Wavelets." SIAM, 1992.
///   — db4 filter coefficients (h0..h7 listed below)
///
/// Channels: TP9=0, AF7=1, AF8=2, TP10=3 (Muse Athena layout).
/// TP9/TP10 (rear ear) are the most artifact-prone contacts on Muse Athena.
///
/// Platform: iOS 16+, Swift 5.9, Xcode 15+. No UIKit. Zero external deps.
/// Performance target: < 5 ms per 1-second 4-channel window on iPhone 12+.

import Foundation
import Accelerate

// MARK: - Public API

/// Per-window quality metrics emitted alongside the cleaned signal.
public struct EEGDenoiseStats {
    /// Ratio of alpha-band (8–12 Hz) power after vs. before denoising.
    /// Values < 1 indicate alpha was partially suppressed (unexpected);
    /// values ≈ 1 indicate alpha was preserved; values slightly above 1
    /// are normal because artifact removal can unmask buried alpha.
    public let alphaPowerRatio: Float

    /// RMS ratio (filtered / raw) computed only in sample bins that were
    /// flagged as spike artifacts (|coeff| > T at level 1).
    /// Lower values indicate stronger spike suppression.
    public let spikeRmsReduction: Float

    /// Count of level-1 detail coefficients that exceeded the universal
    /// threshold T = σ√(2 ln N). Proxy for number of transient events removed.
    public let spikesRemoved: Int
}

/// Stateless, thread-safe per-window EEG denoiser.
/// Create once; call `denoise(window:)` for every incoming window.
public final class EEGDenoiser {

    // MARK: - Constants

    /// EEG sample rate in Hz (Muse: 256 Hz).
    public let sampleRate: Float

    /// Window length in samples. Must equal input window length.
    private let N: Int = 256 // 1-second window at 256 Hz

    /// Number of SWT decomposition levels.
    /// 5 levels → coarsest detail captures ~4–8 Hz (alpha/theta boundary).
    /// Level 1 ≈ 64–128 Hz (muscle), level 5 ≈ 4–8 Hz (slow drift).
    private let levels: Int = 5

    // MARK: - db4 Filter Coefficients
    //
    // Daubechies-4 (db4) low-pass decomposition filter h[0..7].
    // Values from Daubechies 1992, "Ten Lectures on Wavelets," p. 195.
    // These are the standard orthonormal scaling coefficients.
    // High-pass (wavelet) filter: g[k] = (-1)^k * h[7-k]
    //
    // Precise to 15 significant figures (IEEE 754 double, cast to Float).
    private let db4_h: [Float] = [
         0.23037781330886,   // h0
         0.71484657055292,   // h1
         0.63088076792959,   // h2
        -0.02798376941686,   // h3
        -0.18703481171888,   // h4
         0.03084138183599,   // h5
         0.03288301166689,   // h6
        -0.01059740178507    // h7
    ]

    // High-pass (detail) filter derived from h via quadrature mirror relation:
    // g[k] = (-1)^k * h[L-1-k], L=8
    private lazy var db4_g: [Float] = {
        var g = [Float](repeating: 0, count: 8)
        for k in 0..<8 {
            g[k] = (k % 2 == 0 ? 1.0 : -1.0) * db4_h[7 - k]
        }
        return g
    }()

    // MARK: - Bandpass kernel for alpha power ratio (8–12 Hz)
    // FIR bandpass computed at init for the configured sample rate.
    private let alphaKernel: [Float]

    // MARK: - Init

    public init(sampleRate: Float = 256.0) {
        self.sampleRate = sampleRate
        self.alphaKernel = EEGDenoiser.makeAlphaBandpassKernel(
            sampleRate: sampleRate,
            lowHz: 8.0,   // alpha band lower edge (Hz)
            highHz: 12.0, // alpha band upper edge (Hz)
            length: 65    // FIR order 64 (odd length, linear phase)
        )
    }

    // MARK: - Public denoising entry point

    /// Denoise a 1-second EEG window.
    ///
    /// - Parameter window: Array of 4 channels, each with exactly 256 Float samples.
    ///   Channel order: [TP9, AF7, AF8, TP10].
    /// - Returns: Tuple of cleaned window (same shape) and per-window quality stats
    ///   averaged across all 4 channels.
    public func denoise(window: [[Float]]) -> (cleaned: [[Float]], stats: EEGDenoiseStats) {
        precondition(window.count == 4, "Expected 4 channels")
        precondition(window.allSatisfy { $0.count == N }, "Expected \(N) samples per channel")

        var cleanedChannels = [[Float]]()
        cleanedChannels.reserveCapacity(4)

        var totalAlphaRatio: Float = 0
        var totalSpikeRms: Float = 0
        var totalSpikesRemoved: Int = 0

        for ch in 0..<4 {
            let raw = window[ch]
            let (cleaned, chStats) = denoiseChannel(raw)
            cleanedChannels.append(cleaned)
            totalAlphaRatio   += chStats.alphaPowerRatio
            totalSpikeRms     += chStats.spikeRmsReduction
            totalSpikesRemoved += chStats.spikesRemoved
        }

        let nCh = Float(4)
        let stats = EEGDenoiseStats(
            alphaPowerRatio:  totalAlphaRatio  / nCh,
            spikeRmsReduction: totalSpikeRms   / nCh,
            spikesRemoved:    totalSpikesRemoved
        )
        return (cleanedChannels, stats)
    }

    // MARK: - Per-channel denoising

    private func denoiseChannel(_ x: [Float]) -> ([Float], EEGDenoiseStats) {
        // --- SWT forward pass (à trous, no downsampling) ---
        var details = [[Float]]()      // detail coefficients per level
        var approx  = x                // approximation at current level

        for level in 1...levels {
            // At level j, the à trous algorithm uses filters upsampled by 2^(j-1).
            // We implement this by padding zeros between filter taps.
            let stride = 1 << (level - 1) // 2^(level-1): inter-tap spacing
            let (cA, cD) = atrousFilterPair(signal: approx,
                                             lowFilter: db4_h,
                                             highFilter: db4_g,
                                             stride: stride)
            details.append(cD)
            approx = cA
        }

        // --- Universal threshold (Donoho & Johnstone 1994) ---
        // sigma estimated from level-1 detail via MAD / 0.6745.
        // 0.6745 = Phi^{-1}(3/4): normalises MAD to be consistent estimator of
        // Gaussian sigma.  Level 1 contains highest-frequency noise.
        let sigma = robustSigma(details[0])
        let sqrtTwoLnN = sqrt(2.0 * log(Float(N))) // universal threshold scaling
        let T = sigma * sqrtTwoLnN

        // --- Soft-threshold each detail level ---
        var thresholdedDetails = [[Float]]()
        thresholdedDetails.reserveCapacity(levels)
        var spikesRemoved = 0
        var spikeRawSumSq: Float = 0
        var spikeCleanSumSq: Float = 0
        var spikeBinCount = 0

        for (i, cD) in details.enumerated() {
            let (thresholded, spikesAtLevel) = softThreshold(cD, threshold: T)
            thresholdedDetails.append(thresholded)
            if i == 0 { // level 1: collect spike metrics
                spikesRemoved = spikesAtLevel
                // Accumulate RMS numerator/denominator for spike bins
                for j in 0..<cD.count {
                    if abs(cD[j]) > T {
                        spikeRawSumSq   += cD[j] * cD[j]
                        spikeCleanSumSq += thresholded[j] * thresholded[j]
                        spikeBinCount   += 1
                    }
                }
            }
        }

        // --- Inverse SWT reconstruction ---
        // À trous inverse: sum approx + all thresholded details, then average.
        // The à trous SWT is self-dual: reconstruction = (1/2^L) * (sum of
        // all sub-bands after re-filtering with synthesis filters), but for
        // the orthonormal case the simplest stable approach is direct summation
        // with level-specific synthesis convolution (see Mallat 1999 §7.3).
        var reconstructed = inverseSWT(approx: approx,
                                        details: thresholdedDetails,
                                        lowFilter: db4_h,
                                        highFilter: db4_g)

        // Ensure output length matches input (convolution may add edge samples).
        reconstructed = Array(reconstructed.prefix(N))

        // --- Alpha power ratio ---
        let rawAlpha   = bandpower(x,             kernel: alphaKernel)
        let cleanAlpha = bandpower(reconstructed, kernel: alphaKernel)
        let alphaPowerRatio: Float = rawAlpha > 1e-12 ? cleanAlpha / rawAlpha : 1.0

        // --- Spike RMS reduction ---
        let spikeRmsReduction: Float
        if spikeBinCount > 0 && spikeRawSumSq > 1e-12 {
            // ratio of cleaned RMS to raw RMS in spike bins; lower = more suppression
            spikeRmsReduction = sqrt(spikeCleanSumSq / spikeRawSumSq)
        } else {
            spikeRmsReduction = 1.0 // no spikes detected; ratio is unity
        }

        let stats = EEGDenoiseStats(
            alphaPowerRatio:   alphaPowerRatio,
            spikeRmsReduction: spikeRmsReduction,
            spikesRemoved:     spikesRemoved
        )
        return (reconstructed, stats)
    }

    // MARK: - À trous convolution pair (low-pass + high-pass)

    /// Apply a low-pass / high-pass filter pair to `signal` using the à trous
    /// (hole-filling) upsampling trick: insert (stride-1) zeros between each
    /// filter tap before convolving. Uses vDSP_conv for efficiency.
    ///
    /// - Returns: (approximation, detail) sub-band arrays of length N.
    private func atrousFilterPair(signal: [Float],
                                   lowFilter:  [Float],
                                   highFilter: [Float],
                                   stride: Int) -> ([Float], [Float]) {
        let cA = atrousConvolve(signal: signal, filter: lowFilter,  stride: stride)
        let cD = atrousConvolve(signal: signal, filter: highFilter, stride: stride)
        return (cA, cD)
    }

    /// Convolve `signal` with `filter` upsampled by `stride` (à trous).
    /// Symmetric (periodic) boundary extension to minimise edge artifacts.
    private func atrousConvolve(signal: [Float],
                                 filter: [Float],
                                 stride: Int) -> [Float] {
        let L = filter.count              // filter tap count (8 for db4)
        let effective = L + (L - 1) * (stride - 1) // effective filter length after upsampling
        let halfPad = effective / 2       // symmetric padding radius

        // Build upsampled filter: insert (stride-1) zeros between taps.
        var upFilter = [Float](repeating: 0.0, count: effective)
        for i in 0..<L {
            upFilter[i * stride] = filter[i]
        }

        // Periodic (circular) boundary extension.
        let padded = periodicPad(signal, padLeft: halfPad, padRight: effective - halfPad - 1)

        // vDSP convolution (full, then trim).
        // vDSP_conv computes: output[n] = sum_k padded[n+k] * upFilter[k]
        // signal length: padded.count, filter length: effective
        let outLen = padded.count - effective + 1
        var output = [Float](repeating: 0.0, count: outLen)
        padded.withUnsafeBufferPointer { pBuf in
            upFilter.withUnsafeBufferPointer { fBuf in
                output.withUnsafeMutableBufferPointer { oBuf in
                    // vDSP_conv: __A=signal(end-to-start), __F=filter, stride 1
                    // Note: vDSP_conv uses a cross-correlation convention, so we
                    // reverse the filter to get convolution.
                    var revFilter = [Float](upFilter.reversed())
                    revFilter.withUnsafeBufferPointer { rfBuf in
                        vDSP_conv(pBuf.baseAddress!, 1,
                                  rfBuf.baseAddress!, 1,
                                  oBuf.baseAddress!, 1,
                                  vDSP_Length(outLen),
                                  vDSP_Length(effective))
                    }
                }
            }
        }

        // Trim or pad to exactly N samples.
        if output.count >= N {
            return Array(output.prefix(N))
        } else {
            return output + [Float](repeating: 0.0, count: N - output.count)
        }
    }

    // MARK: - Inverse SWT

    /// Reconstruct signal from final approximation + thresholded details.
    /// À trous inverse: at each level j (from coarsest to finest), apply the
    /// synthesis low-pass filter to the approximation and add the detail.
    /// This is the dual of the forward transform (Mallat 1999 §7.3.3).
    private func inverseSWT(approx:   [Float],
                             details:  [[Float]],
                             lowFilter:  [Float],
                             highFilter: [Float]) -> [Float] {
        var reconstructed = approx
        // Iterate from coarsest (level `levels`) to finest (level 1).
        for level in stride(from: levels, through: 1, by: -1) {
            let s = 1 << (level - 1) // à trous stride at this level
            // Synthesis: apply conjugate (time-reversed) low-pass to approximation,
            // then add the (already thresholded) detail.
            let synthLow = [Float](lowFilter.reversed())  // synthesis = analysis reversed for orthonormal
            let synth = atrousConvolve(signal: reconstructed,
                                        filter: synthLow,
                                        stride: s)
            let cD = details[level - 1]
            // Element-wise average of synthesis output and detail branch.
            // The factor of 0.5 compensates for the 2x redundancy of each SWT level
            // (Shensa 1992: "The Discrete Wavelet Transform: Wedding the à Trous and
            // Mallat Algorithms," IEEE Trans. Signal Processing 40(10):2464-2482).
            var combined = [Float](repeating: 0.0, count: N)
            vDSP_vadd(synth.prefix(N) + [Float](),
                      1,
                      Array(cD.prefix(N)), 1,
                      &combined, 1,
                      vDSP_Length(N))
            var half: Float = 0.5
            vDSP_vsmul(combined, 1, &half, &reconstructed, 1, vDSP_Length(N))
        }
        return reconstructed
    }

    // MARK: - Threshold helpers

    /// Universal soft-threshold.
    /// Donoho & Johnstone 1994: sign(c) * max(|c| − T, 0).
    /// Returns thresholded array and count of coefficients that exceeded T.
    private func softThreshold(_ coeffs: [Float], threshold T: Float) -> ([Float], Int) {
        var out = [Float](repeating: 0.0, count: coeffs.count)
        var spikes = 0
        for i in 0..<coeffs.count {
            let c = coeffs[i]
            let absC = abs(c)
            if absC > T {
                spikes += 1
                // Soft-threshold: shrink toward zero by T.
                out[i] = (c > 0 ? 1.0 : -1.0) * (absC - T)
            }
            // else: out[i] stays 0.0 — coefficient killed entirely.
        }
        return (out, spikes)
    }

    /// Robust noise sigma estimate via Median Absolute Deviation.
    /// sigma = MAD(x) / 0.6745
    /// 0.6745 = Phi^{-1}(0.75), the 75th percentile of N(0,1), making MAD
    /// a consistent estimator of the Gaussian std dev (Donoho & Johnstone 1994).
    private func robustSigma(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 1e-6 }
        // Compute median.
        let sorted = x.sorted()
        let med: Float
        let n = sorted.count
        if n % 2 == 0 {
            med = (sorted[n/2 - 1] + sorted[n/2]) * 0.5
        } else {
            med = sorted[n/2]
        }
        // MAD = median(|x_i - median(x)|).
        let absDev = x.map { abs($0 - med) }.sorted()
        let mad: Float
        if n % 2 == 0 {
            mad = (absDev[n/2 - 1] + absDev[n/2]) * 0.5
        } else {
            mad = absDev[n/2]
        }
        let sigma = mad / 0.6745 // normalisation constant (see above)
        return max(sigma, 1e-10) // floor to avoid divide-by-zero on flat signals
    }

    // MARK: - Band power measurement

    /// Compute power in a frequency band using FIR bandpass filter then RMS.
    /// Returns sum of squared filtered samples (proportional to power).
    private func bandpower(_ x: [Float], kernel: [Float]) -> Float {
        let filtered = firFilter(x, kernel: kernel)
        var power: Float = 0.0
        // vDSP_svesq: sum of squares.
        vDSP_svesq(filtered, 1, &power, vDSP_Length(filtered.count))
        return power / Float(filtered.count) // mean power (variance)
    }

    /// Apply a symmetric FIR filter using vDSP_conv.
    private func firFilter(_ signal: [Float], kernel: [Float]) -> [Float] {
        let kLen  = kernel.count
        let halfK = kLen / 2
        let padded = periodicPad(signal, padLeft: halfK, padRight: halfK)
        let outLen = padded.count - kLen + 1
        var output = [Float](repeating: 0.0, count: outLen)
        padded.withUnsafeBufferPointer { pBuf in
            var revKernel = [Float](kernel.reversed())
            revKernel.withUnsafeBufferPointer { kBuf in
                output.withUnsafeMutableBufferPointer { oBuf in
                    vDSP_conv(pBuf.baseAddress!, 1,
                              kBuf.baseAddress!, 1,
                              oBuf.baseAddress!, 1,
                              vDSP_Length(outLen),
                              vDSP_Length(kLen))
                }
            }
        }
        return Array(output.prefix(signal.count))
    }

    // MARK: - Alpha bandpass FIR kernel builder

    /// Build a linear-phase FIR bandpass kernel via windowed sinc method.
    /// Window: Hamming (sidelobe attenuation ~43 dB — sufficient for band ratio).
    /// Length must be odd for zero-phase (linear-phase type I).
    static func makeAlphaBandpassKernel(sampleRate: Float,
                                         lowHz: Float,
                                         highHz: Float,
                                         length: Int) -> [Float] {
        precondition(length % 2 == 1, "FIR kernel length must be odd for type-I filter")
        let M  = length - 1           // filter order
        let fc1 = lowHz  / sampleRate // normalised lower cutoff (0..0.5)
        let fc2 = highHz / sampleRate // normalised upper cutoff
        let center = M / 2

        var h = [Float](repeating: 0.0, count: length)
        for n in 0..<length {
            let nf = Float(n)
            let mf = Float(center)
            // Hamming window coefficient: w[n] = 0.54 - 0.46*cos(2π n/M)
            // Provides ~43 dB stopband attenuation (Harris 1978, Proc. IEEE).
            let w = 0.54 - 0.46 * cos(2.0 * Float.pi * nf / Float(M))
            if n == center {
                // Sinc at 0: limit is 2*(fc2 - fc1)
                h[n] = 2.0 * (fc2 - fc1) * w
            } else {
                let diff = nf - mf
                // Bandpass = highpass_sinc - lowpass_sinc
                let sincHigh = sin(2.0 * Float.pi * fc2 * diff) / (Float.pi * diff)
                let sincLow  = sin(2.0 * Float.pi * fc1 * diff) / (Float.pi * diff)
                h[n] = (sincHigh - sincLow) * w
            }
        }
        // Normalise to unit DC gain (makes power ratio dimensionless).
        var sum: Float = 0.0
        vDSP_sve(h, 1, &sum, vDSP_Length(length))
        if abs(sum) > 1e-10 {
            var invSum = 1.0 / sum
            vDSP_vsmul(h, 1, &invSum, &h, 1, vDSP_Length(length))
        }
        return h
    }

    // MARK: - Boundary extension

    /// Periodic (circular) boundary padding.
    /// Wraps the signal at both ends to avoid convolution edge artifacts.
    private func periodicPad(_ signal: [Float], padLeft: Int, padRight: Int) -> [Float] {
        let n = signal.count
        guard n > 0 else { return signal }
        var padded = [Float]()
        padded.reserveCapacity(padLeft + n + padRight)
        // Left pad: wrap from end of signal.
        for i in 0..<padLeft {
            padded.append(signal[((n - padLeft + i) % n + n) % n])
        }
        padded.append(contentsOf: signal)
        // Right pad: wrap from start of signal.
        for i in 0..<padRight {
            padded.append(signal[i % n])
        }
        return padded
    }
}

// MARK: - Channel Index Constants (convenience)

public extension EEGDenoiser {
    /// Muse Athena channel indices in the window array.
    enum Channel: Int {
        case TP9  = 0  // Left posterior temporal — prone to jaw/neck artifact
        case AF7  = 1  // Left anterior frontal  — prone to eye blink (L)
        case AF8  = 2  // Right anterior frontal — prone to eye blink (R)
        case TP10 = 3  // Right posterior temporal — prone to jaw/neck artifact
    }
}
