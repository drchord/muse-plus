import Accelerate
import Foundation

final class EEGPipeline {
    static let sampleRate: Float = 256.0
    static let windowSize: Int  = 256   // 1-second window
    static let hopSize: Int     = 128   // 50% overlap → output every 0.5 s

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var hannWindow: [Float]
    // 8 slots: EEG1-4 (canonical) + AUX1-4 (Athena). Legacy sends 4, Athena sends 8.
    private var buffers: [[Float]]
    private var activeChannelCount = 0

    // Band powers for all active channels. Consumers filter by channel index.
    var onBandPowers: (([BandPowers]) -> Void)?

    // Aperiodic slope: mean chi across canonical EEG1-4 (nil when R² < 0.85).
    var onAperiodicUpdate: ((Float?) -> Void)?

    // Individual theta peak frequency in Hz (nil until reliability gate: ≥3 sessions, ≥10 min clean).
    var onITPFUpdate: ((Float?) -> Void)?

    // Call when a blink/jaw-clench is detected. Suppresses next 4 windows (~2s).
    func suppressArtifact() {
        suppressWindows = max(suppressWindows, 4)
    }
    private var suppressWindows = 0

    let iTPFTracker = ITPFTracker()

    init() {
        let n = EEGPipeline.windowSize
        log2n    = vDSP_Length(log2(Float(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))!
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        hannWindow = w
        buffers    = Array(repeating: [], count: 8)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func process(_ packet: EEGPacket) {
        let chCount = min(packet.channels.count, 8)
        if chCount > activeChannelCount { activeChannelCount = chCount }

        for ch in 0..<chCount {
            buffers[ch].append(packet.channels[ch])
        }
        guard buffers[0].count >= EEGPipeline.windowSize else { return }

        if suppressWindows > 0 {
            suppressWindows -= 1
            for ch in 0..<activeChannelCount { buffers[ch].removeFirst(EEGPipeline.hopSize) }
            return
        }

        let ts = packet.timestamp
        var allPowers = [BandPowers]()
        var allPSDs   = [[Float]]()
        allPowers.reserveCapacity(activeChannelCount)
        allPSDs.reserveCapacity(activeChannelCount)

        for ch in 0..<activeChannelCount {
            let (psd, bp) = computeWindow(Array(buffers[ch].prefix(EEGPipeline.windowSize)),
                                           channel: ch, timestamp: ts)
            allPowers.append(bp)
            allPSDs.append(psd)
        }

        onBandPowers?(allPowers)

        // IRASA: canonical channels 0-3 only (EEG1-4)
        let chiValues = (0..<min(4, allPSDs.count)).compactMap { ch -> Float? in
            guard let r = AperiodicSlope.fit(psd: allPSDs[ch],
                                              sampleRate: EEGPipeline.sampleRate,
                                              windowSize: EEGPipeline.windowSize),
                  r.r2 >= AperiodicSlope.r2Threshold else { return nil }
            return r.chi
        }
        let meanChi: Float? = chiValues.isEmpty ? nil
            : chiValues.reduce(0, +) / Float(chiValues.count)
        onAperiodicUpdate?(meanChi)

        // iTPF: frontal channels index 1 (AF7) and 2 (AF8)
        if allPSDs.count > 2 {
            iTPFTracker.update(af7PSD: allPSDs[1], af8PSD: allPSDs[2],
                               sampleRate: EEGPipeline.sampleRate,
                               windowSize: EEGPipeline.windowSize)
            onITPFUpdate?(iTPFTracker.currentEstimate)
        }

        for ch in 0..<activeChannelCount { buffers[ch].removeFirst(EEGPipeline.hopSize) }
    }

    // Called on session end — persists Kalman state and adapts process noise.
    func endSession() {
        iTPFTracker.endSession()
    }

    // MARK: - FFT

    // Returns (mag2 power spectrum, BandPowers) for one channel window.
    private func computeWindow(_ samples: [Float], channel: Int,
                                timestamp: TimeInterval) -> ([Float], BandPowers) {
        let n = EEGPipeline.windowSize
        var work = samples

        // 1. Remove DC
        var mean: Float = 0
        vDSP_meanv(work, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(work, 1, &negMean, &work, 1, vDSP_Length(n))

        // 2. Apply Hann window
        vDSP_vmul(work, 1, hannWindow, 1, &work, 1, vDSP_Length(n))

        // 3. Pack real signal as split-complex for vDSP_fft_zrip
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        work.withUnsafeBytes { rawBuf in
            let complexPtr = rawBuf.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
            var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
            vDSP_ctoz(complexPtr, 1, &split, 1, vDSP_Length(n / 2))
        }

        // 4. Real FFT in-place
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // 5. Power spectrum (magnitude squared), normalized
        var mag2 = [Float](repeating: 0, count: n / 2)
        vDSP_zvmags(&split, 1, &mag2, 1, vDSP_Length(n / 2))
        var scale = 1.0 / Float(n * n)
        vDSP_vsmul(mag2, 1, &scale, &mag2, 1, vDSP_Length(n / 2))

        // 6. Log10 mean power per band (frequency resolution: sampleRate / windowSize = 1 Hz/bin)
        let res = EEGPipeline.sampleRate / Float(n)

        func logPow(_ lo: Float, _ hi: Float) -> Float {
            let i0 = max(1, Int((lo / res).rounded()))
            let i1 = min(Int((hi / res).rounded()), n / 2 - 1)
            guard i0 <= i1 else { return -4.0 }
            var sum: Float = 0
            mag2.withUnsafeBufferPointer { ptr in
                vDSP_sve(ptr.baseAddress! + i0, 1, &sum, vDSP_Length(i1 - i0 + 1))
            }
            let meanPow = sum / Float(i1 - i0 + 1)
            return meanPow > 0 ? log10(meanPow) : -4.0
        }

        func peakFreq(_ lo: Float, _ hi: Float) -> Float {
            let i0 = max(1, Int((lo / res).rounded()))
            let i1 = min(Int((hi / res).rounded()), n / 2 - 1)
            guard i0 <= i1 else { return (lo + hi) / 2 }
            var maxVal: Float = 0
            var peakOff: vDSP_Length = 0
            mag2.withUnsafeBufferPointer { ptr in
                vDSP_maxvi(ptr.baseAddress! + i0, 1, &maxVal, &peakOff,
                           vDSP_Length(i1 - i0 + 1))
            }
            return Float(i0 + Int(peakOff)) * res
        }

        let bp = BandPowers(
            delta: logPow(1, 4),   theta: logPow(4, 8),   alpha: logPow(8, 13),
            beta:  logPow(13, 30), gamma: logPow(30, 50),
            deltaPeak: peakFreq(1, 4),   thetaPeak: peakFreq(4, 8),
            alphaPeak: peakFreq(8, 13),  betaPeak:  peakFreq(13, 30),
            gammaPeak: peakFreq(30, 50),
            channel: channel, timestamp: timestamp
        )

        return (mag2, bp)
    }
}
