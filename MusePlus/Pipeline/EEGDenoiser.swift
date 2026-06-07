/// EEGDenoiser.swift
/// MusePlus — Real-time 3-stage EEG artifact denoiser
///
/// Pipeline (per call to denoise(window:)):
///   Stage 1 — SWT soft-thresholding (per-channel)
///   Stage 2 — Riemannian Potato artifact detection + fallback reconstruction
///   Stage 3 — rASR (lite) PCA-based component reconstruction
///
/// Stage 1 algorithm: Stationary Wavelet Transform (à trous, no downsampling)
/// with Daubechies-4 wavelet, 5 decomposition levels, universal soft thresholding.
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
/// - Barachant A, Andreev A, Congedo M. "The Riemannian Potato: an automatic and
///   adaptive artifact detection method for online experiments using Riemannian
///   geometry." TOBI Workshop IV, Sion, Switzerland, 2013. — Riemannian Potato
///   artifact detector. (Note: prior commit incorrectly cited "Barachant & Bonnet";
///   the actual Potato paper is Barachant, Andreev & Congedo. Bonnet is on
///   Barachant's 2011/2012 BCI classification papers, a different lineage.)
/// - Arsigny V, Fillard P, Pennec X, Ayache N. "Log-Euclidean metrics for fast
///   and simple calculus on diffusion tensors." Magn. Reson. Med. 56:411-421, 2006.
///   — Log-Euclidean framework for SPD matrix averaging
/// - Mullen TR et al. "Real-time neuroimaging and cognitive monitoring using
///   wearable dry EEG." IEEE Trans. Biomed. Eng. 62(11):2553-2567, 2015.
///   — ASR (Artifact Subspace Reconstruction) algorithm
/// - Blum S et al. "A Riemannian modification of Artifact Subspace Reconstruction
///   for EEG artifact handling." Front. Hum. Neurosci. 13:141, 2019.
///   — RANSAC-based clean reference selection for rASR
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

    // MARK: Stage 2 — Riemannian Potato (Barachant, Andreev & Congedo 2013)

    /// True if the Riemannian Potato flagged this window as a gross artifact.
    /// Flagging criterion: Riemannian distance d > mean(d_history) + 2.5*std(d_history).
    /// Threshold multiplier 2.5 from Barachant, Andreev & Congedo 2013 original formulation.
    public let potatoFlagged: Bool

    /// Mahalanobis-like distance in the Riemannian metric between the current
    /// window's sample covariance matrix C and the running geometric mean G.
    /// d = sqrt( trace( log(G^{-1/2} C G^{-1/2})^2 ) ).
    /// Zero when buffer is not yet full (< 60 windows) or on matrix-op failure.
    public let potatoDistance: Float

    // MARK: Stage 3 — rASR lite (Mullen 2015 / Blum 2019)

    /// Number of PCA components whose variance exceeded 5σ above the
    /// clean-reference distribution and were zeroed + reconstructed.
    /// Zero when buffer is not yet full or on decomposition failure.
    public let asrComponentsReplaced: Int
}

/// Stateful, per-session EEG denoiser.
/// Create once; call `denoise(window:)` for every incoming window.
/// Internal rolling buffers accumulate history for stages 2 and 3.
/// NOT thread-safe — wrap in a serial DispatchQueue if called from multiple threads.
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

    // MARK: - Rolling buffer constants (stages 2 & 3)

    /// Number of windows in the rolling history buffer (≈ 60 seconds at 1 Hz).
    /// Used by both Riemannian Potato and rASR as the "clean reference" window.
    /// Value: 60 — as specified in Barachant, Andreev & Congedo 2013 and Mullen 2015.
    private let bufferCapacity: Int = 60

    /// Number of EEG channels (fixed: TP9, AF7, AF8, TP10).
    private let nChannels: Int = 4

    // MARK: - Rolling window buffer (stages 2 & 3 shared)

    /// FIFO of the last `bufferCapacity` SWT-cleaned windows.
    /// Each element is [[Float]] — 4 channels × 256 samples.
    /// Only NON-flagged windows (Potato accepted) are stored here,
    /// so this buffer represents "clean" EEG for rASR reference.
    private var windowBuffer: [[[Float]]] = []

    // MARK: - Riemannian Potato state (stage 2)

    /// Running geometric mean of covariance matrices G, stored as flat 4×4 (row-major).
    /// Initialised to nil until the first window is processed.
    ///
    /// Update rule (B83 round-2): TRUE log-Euclidean mean via eigendecomposition.
    ///   G_new = expm( (1-α) * logm(G_old) + α * logm(C_new) )
    /// Implemented in `applyRiemannianPotato` using `mat4LogSymm` + `mat4ExpSymm`,
    /// which reconstruct V * diag(f(λ)) * V^T from the existing `eigendecompose4`
    /// Jacobi solver. Falls back to Euclidean approximation only on
    /// eigendecomposition failure (degenerate / non-SPD input).
    /// α = 0.05 — exponential forgetting factor, ~20-window effective memory.
    /// cite: Arsigny V et al. Log-Euclidean metrics. Magn Reson Med 56:411-421, 2006.
    private var potatoG: [Float]? = nil  // 4×4 row-major

    /// α = 0.05 for log-Euclidean running average.
    /// Chosen so the effective window is ~1/α = 20 windows (Barachant 2013).
    private let potatoAlpha: Float = 0.05  // cite: Barachant, Andreev & Congedo 2013

    /// Running history of potato distances for adaptive thresholding.
    private var potatoDistances: [Float] = []

    /// Threshold multiplier: flag if d > mean + 2.5*std.
    /// Value 2.5 from Barachant, Andreev & Congedo 2013 original formulation.
    private let potatoZThreshold: Float = 2.5  // cite: Barachant, Andreev & Congedo 2013

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

    /// Denoise a 1-second EEG window through a 3-stage cascade:
    ///   1. SWT soft-thresholding (per-channel)
    ///   2. Riemannian Potato artifact detection (across-channel)
    ///   3. rASR lite PCA reconstruction (across-channel)
    ///
    /// Stages 2 and 3 are skipped (fallback stats returned) until the
    /// rolling buffer contains at least `bufferCapacity` (60) clean windows.
    ///
    /// - Parameter window: Array of 4 channels, each with exactly 256 Float samples.
    ///   Channel order: [TP9, AF7, AF8, TP10].
    /// - Returns: Tuple of cleaned window (same shape) and per-window quality stats
    ///   averaged across all 4 channels, plus per-window artifact flags.
    public func denoise(window: [[Float]]) -> (cleaned: [[Float]], stats: EEGDenoiseStats) {
        precondition(window.count == 4, "Expected 4 channels")
        precondition(window.allSatisfy { $0.count == N }, "Expected \(N) samples per channel")

        // ── Stage 1: SWT soft-thresholding (per-channel) ──────────────────────
        var cleanedChannels = [[Float]]()
        cleanedChannels.reserveCapacity(4)

        var totalAlphaRatio: Float = 0
        var totalSpikeRms: Float = 0
        var totalSpikesRemoved: Int = 0

        for ch in 0..<4 {
            let raw = window[ch]
            let (cleaned, chStats) = denoiseChannel(raw)
            cleanedChannels.append(cleaned)
            totalAlphaRatio    += chStats.alphaPowerRatio
            totalSpikeRms      += chStats.spikeRmsReduction
            totalSpikesRemoved += chStats.spikesRemoved
        }

        let nCh = Float(4)
        let swtAlphaRatio     = totalAlphaRatio    / nCh
        let swtSpikeRms       = totalSpikeRms      / nCh
        let swtSpikesRemoved  = totalSpikesRemoved

        // Fallback stats (returned when buffer not yet full or on error)
        let fallbackStats = EEGDenoiseStats(
            alphaPowerRatio:      swtAlphaRatio,
            spikeRmsReduction:    swtSpikeRms,
            spikesRemoved:        swtSpikesRemoved,
            potatoFlagged:        false,
            potatoDistance:       0.0,
            asrComponentsReplaced: 0
        )

        // ── Buffer guard: stages 2+3 need a full clean-reference buffer ────────
        guard windowBuffer.count >= bufferCapacity else {
            // Buffer not yet full — store this window (no potato check yet) and
            // return SWT-only result.
            appendToBuffer(cleanedChannels)
            return (cleanedChannels, fallbackStats)
        }

        // ── Stage 2: Riemannian Potato ─────────────────────────────────────────
        // Dispatch: applyRiemannianPotato updates potatoG, potatoDistances, and
        // returns the (possibly reconstructed) channels + artifact flag/distance.
        let (potatoChannels, potatoFlagged, potatoDistance) =
            applyRiemannianPotato(channels: cleanedChannels)

        // Update rolling buffer: only store windows that Potato accepted.
        if !potatoFlagged {
            appendToBuffer(potatoChannels)
        }

        // ── Stage 3: rASR lite ────────────────────────────────────────────────
        // rASR does the real reconstruction; Potato's fallback (channel mean) is
        // intentionally simple — see comment in applyRiemannianPotato.
        let (asrChannels, asrComponentsReplaced) =
            applyRASR(channels: potatoChannels)

        let stats = EEGDenoiseStats(
            alphaPowerRatio:       swtAlphaRatio,
            spikeRmsReduction:     swtSpikeRms,
            spikesRemoved:         swtSpikesRemoved,
            potatoFlagged:         potatoFlagged,
            potatoDistance:        potatoDistance,
            asrComponentsReplaced: asrComponentsReplaced
        )
        return (asrChannels, stats)
    }

    // MARK: - Rolling buffer helpers

    /// Append `channels` to the rolling buffer, evicting oldest entry when full.
    private func appendToBuffer(_ channels: [[Float]]) {
        if windowBuffer.count >= bufferCapacity {
            windowBuffer.removeFirst()
        }
        windowBuffer.append(channels)
    }

    // MARK: - Stage 2: Riemannian Potato
    //
    // Reference: Barachant A, Bonnet S. "Riemannian geometry applied to BCI
    // classification." TOBI Workshop IV, 2013.
    //
    // The "potato" is a convex region in the Riemannian manifold of SPD matrices.
    // Windows whose covariance matrix falls outside it (large Riemannian distance
    // from the geometric mean G) are flagged as artifacts.
    //
    // Distance metric: d = sqrt( trace( log(G^{-1/2} C G^{-1/2})^2 ) )
    // See Barachant 2013, eq. (3). We approximate log via eigendecomposition of
    // the 4×4 whitened covariance matrix (see mat4LogSymm).

    /// Apply Riemannian Potato to one multi-channel window.
    /// Returns: (processed channels, flagged, riemannian distance).
    /// On any matrix-operation failure, returns SWT channels with flagged=false, d=0.
    private func applyRiemannianPotato(
        channels: [[Float]]
    ) -> (channels: [[Float]], flagged: Bool, distance: Float) {

        // ── Compute 4×4 sample covariance matrix C ──────────────────────────
        guard let C = sampleCovariance4(channels: channels) else {
            // Degenerate/singular input — skip stage
            return (channels, false, 0.0)
        }

        // ── Update running geometric mean G via TRUE log-Euclidean update ───
        // G_new = expm( (1-α) * logm(G_old) + α * logm(C) )
        // This is the actual log-Euclidean mean (Arsigny et al. 2006), not the
        // Euclidean approximation used in the prior commit. Uses eigendecompose4
        // to compute logm and expm exactly for SPD 4×4 matrices.
        // Falls back to Euclidean update if eigendecomp fails (rare; degenerate input).
        // cite: Arsigny V et al. Log-Euclidean metrics. Magn Reson Med 56:411-421, 2006.
        var G: [Float]
        if let existing = potatoG {
            if let logG = mat4LogSymm(existing), let logC = mat4LogSymm(C) {
                let mixed = mat4Add(
                    mat4Scale(logG, scalar: 1.0 - potatoAlpha),
                    mat4Scale(logC, scalar: potatoAlpha)
                )
                if let exped = mat4ExpSymm(mixed) {
                    G = exped
                } else {
                    // expm failed — Euclidean fallback
                    G = mat4Add(mat4Scale(existing, scalar: 1.0 - potatoAlpha),
                                 mat4Scale(C,        scalar: potatoAlpha))
                }
            } else {
                // logm failed — Euclidean fallback
                G = mat4Add(mat4Scale(existing, scalar: 1.0 - potatoAlpha),
                             mat4Scale(C,        scalar: potatoAlpha))
            }
        } else {
            G = C  // First window: initialise G = C
        }
        potatoG = G

        // ── Compute Riemannian distance d(G, C) ─────────────────────────────
        // d = sqrt( trace( logm(G^{-1/2} C G^{-1/2})^2 ) )
        // Implementation:
        //   1. Whitened matrix S = G^{-1/2} C G^{-1/2}
        //      For SPD G: G^{-1/2} via eigendecomposition of G.
        //   2. logm(S) via eigendecomposition (S is SPD when G,C are SPD).
        //   3. trace(logm(S)^2) = sum of squared eigenvalues of logm(S).
        let distance: Float
        if let d = riemannianDistance(G: G, C: C) {
            distance = d
        } else {
            // Matrix op failed — skip stage, return SWT result
            return (channels, false, 0.0)
        }

        // ── Adaptive threshold via running z-score ───────────────────────────
        potatoDistances.append(distance)
        if potatoDistances.count > bufferCapacity * 2 {
            potatoDistances.removeFirst()  // bounded history
        }

        var flagged = false
        if potatoDistances.count >= 5 {  // need a few samples for stable stats
            let dMean = potatoDistances.reduce(0, +) / Float(potatoDistances.count)
            let dVar  = potatoDistances.map { ($0 - dMean) * ($0 - dMean) }
                            .reduce(0, +) / Float(potatoDistances.count)
            let dStd  = sqrt(max(dVar, 1e-10))
            // Flag if distance exceeds mean + 2.5*std (Barachant, Andreev & Congedo 2013)
            flagged = distance > dMean + potatoZThreshold * dStd
        }

        // ── Fallback reconstruction if flagged ───────────────────────────────
        // FALLBACK RECONSTRUCTION (B84): replace each channel with its
        // channel-mean from the rolling buffer. This is simple and defensible
        // for the flagging pass; rASR (stage 3) does the real signal recovery.
        // cite: Barachant, Andreev & Congedo 2013 (flagging); rASR reconstruction in stage 3.
        if flagged {
            var reconstructed = [[Float]]()
            reconstructed.reserveCapacity(nChannels)
            for ch in 0..<nChannels {
                // Channel mean across all buffered windows (time × windows)
                var chMean = [Float](repeating: 0.0, count: N)
                for w in windowBuffer {
                    vDSP_vadd(chMean, 1, w[ch], 1, &chMean, 1, vDSP_Length(N))
                }
                var scale = 1.0 / Float(windowBuffer.count)
                vDSP_vsmul(chMean, 1, &scale, &chMean, 1, vDSP_Length(N))
                reconstructed.append(chMean)
            }
            return (reconstructed, true, distance)
        }

        return (channels, false, distance)
    }

    // MARK: - Stage 3: rASR lite
    //
    // Reference:
    //   Mullen TR et al. "Real-time neuroimaging and cognitive monitoring using
    //   wearable dry EEG." IEEE Trans. Biomed. Eng. 62(11):2553-2567, 2015.
    //   — ASR algorithm (Artifact Subspace Reconstruction)
    //   Blum S et al. "A Riemannian modification of Artifact Subspace
    //   Reconstruction for EEG artifact handling." Front. Hum. Neurosci. 13:141, 2019.
    //   — RANSAC clean-reference selection
    //
    // Steps:
    //   1. RANSAC reference selection: pick cleanest 30% of buffer windows by RMS.
    //   2. Build PCA from concatenated reference windows (4-channel PCA).
    //   3. Project current window into PCA basis.
    //   4. Identify components with variance > 5σ above reference distribution.
    //   5. Zero those components and project back.
    //
    // Component variance threshold 5σ: Mullen 2015 Table I default.
    // RANSAC 30% percentile: Blum 2019 §2.2 recommendation.

    /// Apply rASR lite to one multi-channel window.
    /// Returns: (reconstructed channels, number of components replaced).
    /// On failure, returns input unchanged with 0 components replaced.
    private func applyRASR(
        channels: [[Float]]
    ) -> (channels: [[Float]], componentsReplaced: Int) {

        let bufLen = windowBuffer.count
        guard bufLen >= 10 else { return (channels, 0) }  // need enough reference windows

        // ── RANSAC reference selection: cleanest 30% by total RMS ────────────
        // cite: Blum et al. 2019 §2.2 — RANSAC clean-reference selection
        let windowRMS: [Float] = windowBuffer.map { w in
            var totalSq: Float = 0
            for ch in 0..<nChannels {
                var chSq: Float = 0
                vDSP_svesq(w[ch], 1, &chSq, vDSP_Length(N))
                totalSq += chSq
            }
            return sqrt(totalSq / Float(nChannels * N))
        }
        let sortedRMS = windowRMS.sorted()
        // 30% cleanest = lowest RMS windows
        let refCount = max(1, Int(Float(bufLen) * 0.30))  // cite: Blum 2019
        let rmsThreshold = sortedRMS[refCount - 1]
        let refWindows = zip(windowBuffer, windowRMS)
            .filter { $0.1 <= rmsThreshold }
            .map { $0.0 }

        guard !refWindows.isEmpty else { return (channels, 0) }

        // ── Build PCA from reference windows ─────────────────────────────────
        // Concatenate all reference windows per channel: refData[ch] = all samples
        // Then compute 4×4 covariance matrix of the reference set.
        let refSamples = refWindows.count * N
        var refMatrix = [[Float]](repeating: [Float](repeating: 0, count: refSamples), count: nChannels)
        for (wi, w) in refWindows.enumerated() {
            for ch in 0..<nChannels {
                let offset = wi * N
                for s in 0..<N {
                    refMatrix[ch][offset + s] = w[ch][s]
                }
            }
        }

        // Reference covariance (nChannels × nChannels)
        guard let refCov = sampleCovarianceN(matrix: refMatrix, nSamples: refSamples) else {
            return (channels, 0)
        }

        // PCA via eigendecomposition of refCov (4×4 symmetric)
        guard let (eigenvalues, eigenvectors) = eigendecompose4(matrix: refCov) else {
            return (channels, 0)
        }

        // ── Reference component variances ────────────────────────────────────
        // For each PCA component k, its variance in the reference set equals
        // its eigenvalue (by definition of PCA).
        let refComponentVar = eigenvalues  // [Float], length 4

        // ── Project current window into PCA basis ─────────────────────────────
        // currentMat[ch][s] — already have this as `channels`
        // Project: componentSignal[k][s] = sum_ch eigenvectors[ch][k] * channels[ch][s]
        var componentSignals = [[Float]](repeating: [Float](repeating: 0, count: N), count: nChannels)
        for k in 0..<nChannels {
            for ch in 0..<nChannels {
                let weight = eigenvectors[ch * nChannels + k]  // col-major: eigvec k
                for s in 0..<N {
                    componentSignals[k][s] += weight * channels[ch][s]
                }
            }
        }

        // ── Compute per-component variance and threshold ──────────────────────
        // Threshold: 5σ above reference component variance (Mullen 2015, Table I)
        var replacedMask = [Bool](repeating: false, count: nChannels)
        var nReplaced = 0
        for k in 0..<nChannels {
            var compVar: Float = 0
            vDSP_svesq(componentSignals[k], 1, &compVar, vDSP_Length(N))
            compVar /= Float(N)
            let refVar = max(refComponentVar[k], 1e-12)
            // Flag if component variance exceeds 5σ above reference.
            // Here we treat refVar as the reference "mean variance" and
            // use sqrt(2*refVar) as a proxy σ (chi-distribution for variance).
            // cite: Mullen TR et al. 2015 — ASR component threshold
            let threshold = refVar + 5.0 * sqrt(2.0 * refVar)  // cite: Mullen 2015
            if compVar > threshold {
                replacedMask[k] = true
                componentSignals[k] = [Float](repeating: 0.0, count: N)  // zero component
                nReplaced += 1
            }
        }

        guard nReplaced > 0 else { return (channels, 0) }

        // ── Project back to channel space ─────────────────────────────────────
        // reconstructed[ch][s] = sum_k eigenvectors[ch][k] * componentSignals[k][s]
        var reconstructed = [[Float]](repeating: [Float](repeating: 0, count: N), count: nChannels)
        for ch in 0..<nChannels {
            for k in 0..<nChannels {
                let weight = eigenvectors[ch * nChannels + k]
                for s in 0..<N {
                    reconstructed[ch][s] += weight * componentSignals[k][s]
                }
            }
        }

        return (reconstructed, nReplaced)
    }

    // MARK: - Matrix helpers (4×4 SPD, stored row-major as [Float], length 16)

    /// Compute 4×4 sample covariance matrix from `channels` (4 × N Float arrays).
    /// Returns nil if input is degenerate (zero variance).
    private func sampleCovariance4(channels: [[Float]]) -> [Float]? {
        var C = [Float](repeating: 0, count: 16)
        // Subtract channel means first (centre the data).
        var means = [Float](repeating: 0, count: nChannels)
        for ch in 0..<nChannels {
            vDSP_meanv(channels[ch], 1, &means[ch], vDSP_Length(N))
        }
        for i in 0..<nChannels {
            for j in i..<nChannels {
                // cov(i,j) = E[(xi - μi)(xj - μj)]
                var sumProd: Float = 0
                for s in 0..<N {
                    sumProd += (channels[i][s] - means[i]) * (channels[j][s] - means[j])
                }
                let cov = sumProd / Float(N - 1)
                C[i * nChannels + j] = cov
                C[j * nChannels + i] = cov  // symmetric
            }
        }
        // Sanity check: diagonal must be positive
        for i in 0..<nChannels {
            if C[i * nChannels + i] < 1e-20 { return nil }
        }
        return C
    }

    /// Compute nChannels×nChannels sample covariance from a general matrix.
    /// `matrix`: nChannels × nSamples. Returns nil on degenerate input.
    private func sampleCovarianceN(matrix: [[Float]], nSamples: Int) -> [Float]? {
        var C = [Float](repeating: 0, count: nChannels * nChannels)
        var means = [Float](repeating: 0, count: nChannels)
        for ch in 0..<nChannels {
            vDSP_meanv(matrix[ch], 1, &means[ch], vDSP_Length(nSamples))
        }
        for i in 0..<nChannels {
            for j in i..<nChannels {
                var sumProd: Float = 0
                for s in 0..<nSamples {
                    sumProd += (matrix[i][s] - means[i]) * (matrix[j][s] - means[j])
                }
                let cov = sumProd / Float(nSamples - 1)
                C[i * nChannels + j] = cov
                C[j * nChannels + i] = cov
            }
        }
        for i in 0..<nChannels {
            if C[i * nChannels + i] < 1e-20 { return nil }
        }
        return C
    }

    /// Eigendecompose a 4×4 symmetric matrix via Jacobi iteration.
    /// Returns (eigenvalues [Float], eigenvectors [Float] column-major 4×4).
    /// Eigenvalues sorted ascending. Returns nil if iteration fails to converge.
    ///
    /// We use Jacobi because: (a) N=4 is tiny — 4×4 Jacobi converges in <15
    /// sweeps, (b) Accelerate's ssyev requires a Fortran-style LAPACK bridging
    /// that adds boilerplate on iOS, (c) simd_float4x4 has no built-in eig.
    private func eigendecompose4(matrix: [Float]) -> (eigenvalues: [Float], eigenvectors: [Float])? {
        let n = 4
        var A = matrix  // working copy (will be destroyed)
        // Eigenvectors start as identity
        var V = [Float](repeating: 0, count: n * n)
        for i in 0..<n { V[i * n + i] = 1.0 }

        let maxIter = 100
        let tol: Float = 1e-10

        for _ in 0..<maxIter {
            // Find largest off-diagonal element
            var maxOff: Float = 0
            var p = 0, q = 1
            for i in 0..<n {
                for j in (i+1)..<n {
                    let val = abs(A[i * n + j])
                    if val > maxOff { maxOff = val; p = i; q = j }
                }
            }
            if maxOff < tol { break }

            // Jacobi rotation to zero A[p,q]
            let App = A[p * n + p]
            let Aqq = A[q * n + q]
            let Apq = A[p * n + q]
            let theta = (Aqq - App) / (2.0 * Apq)
            let t: Float = (theta >= 0)
                ? 1.0 / (theta + sqrt(1.0 + theta * theta))
                : 1.0 / (theta - sqrt(1.0 + theta * theta))
            let c = 1.0 / sqrt(1.0 + t * t)
            let s = t * c

            // Update A
            A[p * n + p] = App - t * Apq
            A[q * n + q] = Aqq + t * Apq
            A[p * n + q] = 0
            A[q * n + p] = 0
            for r in 0..<n where r != p && r != q {
                let Arp = A[r * n + p]
                let Arq = A[r * n + q]
                A[r * n + p] = c * Arp - s * Arq
                A[p * n + r] = A[r * n + p]
                A[r * n + q] = s * Arp + c * Arq
                A[q * n + r] = A[r * n + q]
            }
            // Update eigenvectors
            for r in 0..<n {
                let Vrp = V[r * n + p]
                let Vrq = V[r * n + q]
                V[r * n + p] = c * Vrp - s * Vrq
                V[r * n + q] = s * Vrp + c * Vrq
            }
        }

        // Extract eigenvalues from diagonal of A
        var eigenvalues = (0..<n).map { A[$0 * n + $0] }

        // Sort eigenvalues ascending, permute eigenvectors accordingly
        let idx = eigenvalues.indices.sorted { eigenvalues[$0] < eigenvalues[$1] }
        let sortedEV = idx.map { eigenvalues[$0] }
        var sortedV = [Float](repeating: 0, count: n * n)
        for (newCol, oldCol) in idx.enumerated() {
            for row in 0..<n {
                sortedV[row * n + newCol] = V[row * n + oldCol]
            }
        }
        eigenvalues = sortedEV

        // Validate: all eigenvalues positive (SPD check)
        guard eigenvalues.allSatisfy({ $0 > 1e-15 }) else { return nil }

        return (eigenvalues, sortedV)
    }

    /// Compute Riemannian distance between SPD matrices G and C.
    /// d = sqrt( sum_i lambda_i^2 ) where lambda_i = eigenvalues of log(G^{-1/2} C G^{-1/2}).
    /// cite: Barachant, Andreev & Congedo 2013, eq. (3)
    private func riemannianDistance(G: [Float], C: [Float]) -> Float? {
        // Compute G^{-1/2} via eigendecomposition of G:
        //   G = V D V^T  =>  G^{-1/2} = V D^{-1/2} V^T
        guard let (gEVals, gEVecs) = eigendecompose4(matrix: G) else { return nil }

        let n = 4
        // Build G^{-1/2} = V * diag(1/sqrt(lambda)) * V^T
        var Ghalf_inv = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n {
                var sum: Float = 0
                for k in 0..<n {
                    // V[i,k] * (1/sqrt(lambda_k)) * V[j,k]
                    sum += gEVecs[i * n + k] * (1.0 / sqrt(gEVals[k])) * gEVecs[j * n + k]
                }
                Ghalf_inv[i * n + j] = sum
            }
        }

        // Compute S = G^{-1/2} C G^{-1/2}  (matrix triple product)
        // S = Ghalf_inv * C * Ghalf_inv
        let temp = mat4Mul(Ghalf_inv, C)
        let S    = mat4Mul(temp, Ghalf_inv)

        // logm(S): S should be SPD; get eigenvalues and take log
        guard let (sEVals, _) = eigendecompose4(matrix: S) else { return nil }

        // d = sqrt( sum_i log(lambda_i)^2 )
        // cite: Barachant, Andreev & Congedo 2013
        let sumSq = sEVals.map { l -> Float in
            guard l > 1e-15 else { return 0 }
            let logL = log(l)
            return logL * logL
        }.reduce(0, +)

        return sqrt(sumSq)
    }

    // MARK: - Symmetric matrix logm / expm (B83 round-2 — replaces Euclidean approximation)

    /// Matrix logarithm of a symmetric positive-definite 4×4 matrix.
    /// logm(M) = V * diag(log(λ_i)) * V^T where M = V * diag(λ_i) * V^T.
    /// Returns nil on degenerate input (eigendecomp fails or any λ ≤ 0).
    /// cite: Arsigny et al. 2006 — Log-Euclidean SPD calculus
    private func mat4LogSymm(_ M: [Float]) -> [Float]? {
        guard let (eVals, eVecs) = eigendecompose4(matrix: M) else { return nil }
        let n = 4
        // log of eigenvalues — must all be positive for SPD.
        var logVals = [Float](repeating: 0, count: n)
        for i in 0..<n {
            guard eVals[i] > 1e-15 else { return nil }
            logVals[i] = log(eVals[i])
        }
        return reconstructSymm(eigenvalues: logVals, eigenvectors: eVecs)
    }

    /// Matrix exponential of a symmetric matrix.
    /// expm(M) = V * diag(exp(λ_i)) * V^T. Always positive-definite.
    /// cite: Arsigny et al. 2006
    private func mat4ExpSymm(_ M: [Float]) -> [Float]? {
        guard let (eVals, eVecs) = eigendecompose4(matrix: M) else { return nil }
        let n = 4
        let expVals = (0..<n).map { exp(eVals[$0]) }
        return reconstructSymm(eigenvalues: expVals, eigenvectors: eVecs)
    }

    /// Reconstruct symmetric matrix from V * diag(f) * V^T.
    /// `eigenvectors` row-major 4×4 (column k = k-th eigenvector).
    private func reconstructSymm(eigenvalues f: [Float], eigenvectors V: [Float]) -> [Float] {
        let n = 4
        var out = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n {
                var sum: Float = 0
                for k in 0..<n {
                    // V[i,k] * f[k] * V[j,k]
                    sum += V[i * n + k] * f[k] * V[j * n + k]
                }
                out[i * n + j] = sum
            }
        }
        return out
    }

    // MARK: - 4×4 matrix arithmetic (row-major [Float], length 16)

    private func mat4Mul(_ A: [Float], _ B: [Float]) -> [Float] {
        var C = [Float](repeating: 0, count: 16)
        for i in 0..<4 {
            for j in 0..<4 {
                var s: Float = 0
                for k in 0..<4 { s += A[i * 4 + k] * B[k * 4 + j] }
                C[i * 4 + j] = s
            }
        }
        return C
    }

    private func mat4Scale(_ A: [Float], scalar: Float) -> [Float] {
        return A.map { $0 * scalar }
    }

    private func mat4Add(_ A: [Float], _ B: [Float]) -> [Float] {
        return zip(A, B).map(+)
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

        // Stage-2 and stage-3 fields are not applicable at the per-channel level;
        // they are filled in by the top-level denoise(window:) after all channels
        // have been processed.  Use sentinel/zero values here.
        let stats = EEGDenoiseStats(
            alphaPowerRatio:       alphaPowerRatio,
            spikeRmsReduction:     spikeRmsReduction,
            spikesRemoved:         spikesRemoved,
            potatoFlagged:         false,
            potatoDistance:        0.0,
            asrComponentsReplaced: 0
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
                    let revFilter = [Float](upFilter.reversed())
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
            // Materialize Slices to Arrays so vDSP_vadd has contiguous storage.
            let synthN = Array(synth.prefix(N))
            let cDN    = Array(cD.prefix(N))
            vDSP_vadd(synthN, 1, cDN, 1, &combined, 1, vDSP_Length(N))
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
            let revKernel = [Float](kernel.reversed())
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
