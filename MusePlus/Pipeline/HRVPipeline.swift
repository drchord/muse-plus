import Accelerate
import Foundation

// AMPD-based R-peak detection (Scholkmann et al. 2012) on 64 Hz Optics7/8 signal.
// Athena only — fires via opticsRawSample subject; never fires on legacy Muse S 2019.
// RMSSD per ESC/NASPE Task Force 1996 (5-min minimum window).
// LF/HF via linear-interpolated 4 Hz R-R series + Hann-windowed FFT.
final class HRVPipeline {

    // Fires on main thread: (rmssd_ms, lfhf_ratio?)
    var onRMSSD: ((Double, Double?) -> Void)?

    // B107: per-window latest values for session-end attachment
    private(set) var latestSDNN: Double = 0.0
    private(set) var latestSD1:  Double = 0.0
    private(set) var latestSD2:  Double?

    // B107: fires with extended HRV metrics (alongside onRMSSD)
    var onHRVExtended: ((sdnn: Double, sd1: Double, sd2: Double?) -> Void)?

    private static let sampleRate:    Double = 64.0
    private static let windowSamples: Int    = 19200   // 5 * 60 * 64
    private static let updateInterval: Int   = 64      // run AMPD every 1 s
    private static let kMax:           Int   = 128     // covers 30 BPM (period = 2 s = 128 samples)
    private static let minPeaks:       Int   = 30

    // Fixed 2048-point double-precision FFT setup for LF/HF.
    private static let lfhfFFTSize: Int = 2048
    private let fftSetup: FFTSetupD
    private static let interpRate: Double = 4.0

    private var rawBuffer:     [Double] = []
    private var updateCounter: Int      = 0
    let queue = DispatchQueue(label: "com.drchord.museplus.hrv", qos: .utility)

    init() {
        let log2N = vDSP_Length(log2(Double(Self.lfhfFFTSize)).rounded())
        fftSetup = vDSP_create_fftsetupD(log2N, FFTRadix(FFT_RADIX2))!
    }

    deinit { vDSP_destroy_fftsetupD(fftSetup) }

    // Called from Probe on SDK callback thread — dispatches internally, returns immediately.
    func process(_ sample: Double) {
        queue.async { [self] in
            rawBuffer.append(sample)
            if rawBuffer.count > Self.windowSamples { rawBuffer.removeFirst() }
            updateCounter += 1
            guard updateCounter >= Self.updateInterval,
                  rawBuffer.count >= Self.windowSamples else { return }
            updateCounter = 0
            runAMPD()
        }
    }

    func reset() {
        queue.async { [self] in
            rawBuffer.removeAll()
            updateCounter = 0
        }
    }

    // MARK: - AMPD

    private func runAMPD() {
        let N = rawBuffer.count

        // Detrend: causal 1-s MA subtraction removes baseline wander (breathing ~0.2 Hz).
        var x = rawBuffer
        var trendSum = 0.0
        let trendWin = 64
        var trend = [Double](repeating: 0, count: N)
        for i in 0..<N {
            trendSum += x[i]
            if i >= trendWin { trendSum -= x[i - trendWin] }
            trend[i] = trendSum / Double(min(i + 1, trendWin))
        }
        for i in 0..<N { x[i] -= trend[i] }

        // Normalize
        let mean = x.reduce(0, +) / Double(N)
        for i in 0..<N { x[i] -= mean }
        let std = sqrt(x.map { $0 * $0 }.reduce(0, +) / Double(N))
        guard std > 0 else { return }
        for i in 0..<N { x[i] /= std }

        // Local Maxima Scalogram: find k* by minimizing CV of inter-peak distances.
        // At k = beat period, true R-peaks survive → most regular spacing → minimum CV.
        let Kmax = min(Self.kMax, N / 2)
        var bestK  = 1
        var bestCV = Double.infinity

        for k in 1...Kmax {
            var peaks = [Int]()
            for n in k..<(N - k) {
                if x[n] > x[n - k] && x[n] > x[n + k] { peaks.append(n) }
            }
            guard peaks.count >= 5 else { continue }
            let diffs = zip(peaks.dropFirst(), peaks).map { Double($0 - $1) }
            let mu    = diffs.reduce(0, +) / Double(diffs.count)
            guard mu > 0 else { continue }
            let sigma = sqrt(diffs.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(diffs.count))
            let cv    = sigma / mu
            if cv < bestCV { bestCV = cv; bestK = k }
        }

        // Extract peaks at k*
        var peaks = [Int]()
        for n in bestK..<(N - bestK) {
            if x[n] > x[n - bestK] && x[n] > x[n + bestK] { peaks.append(n) }
        }

        // Physiological gate: 0.33 s (180 BPM) ≤ inter-peak ≤ 2.0 s (30 BPM)
        peaks = filterPeaks(peaks)
        guard peaks.count >= Self.minPeaks else { return }

        // R-R intervals (seconds)
        let rr      = zip(peaks.dropFirst(), peaks).map { Double($0 - $1) / Self.sampleRate }
        let validRR = rr.filter { $0 >= 0.33 && $0 <= 2.0 }
        guard validRR.count >= 5 else { return }

        // Outlier rejection: |RRi − median| > 0.25 s (Clifford 2002 threshold)
        let med     = median(validRR)
        let cleanRR = validRR.filter { abs($0 - med) <= 0.25 }
        guard cleanRR.count >= 5 else { return }

        // RMSSD (ms) — ESC/NASPE formula
        let diffs  = zip(cleanRR.dropFirst(), cleanRR).map { ($0 - $1) * ($0 - $1) }
        let rmssd  = sqrt(diffs.reduce(0, +) / Double(diffs.count)) * 1000.0

        let lfhf   = computeLFHF(cleanRR)

        let sdnn = Self.computeSDNN(cleanRR)
        let sd1  = Self.computeSD1(cleanRR) ?? rmssd / sqrt(2.0)
        let sd2  = Self.computeSD2(cleanRR)
        latestSDNN = sdnn
        latestSD1  = sd1
        latestSD2  = sd2
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onRMSSD?(rmssd, lfhf)
            if let sd2 = sd2 {
                self.onHRVExtended?((sdnn: sdnn, sd1: sd1, sd2: sd2))
            }
        }
    }

    private func filterPeaks(_ peaks: [Int]) -> [Int] {
        guard !peaks.isEmpty else { return [] }
        let minSep = Int(Self.sampleRate * 0.33)   // 21 samples @ 64 Hz
        let maxSep = Int(Self.sampleRate * 2.0)    // 128 samples @ 64 Hz
        var result = [peaks[0]]
        for i in 1..<peaks.count {
            let sep = peaks[i] - result.last!
            if sep >= minSep && sep <= maxSep { result.append(peaks[i]) }
        }
        return result
    }

    // MARK: - LF/HF ratio

    private func computeLFHF(_ rr: [Double]) -> Double? {
        guard rr.count >= 30 else { return nil }

        // Cumulative peak timestamps (seconds)
        var t = [Double](repeating: 0, count: rr.count + 1)
        for i in 1...rr.count { t[i] = t[i - 1] + rr[i - 1] }

        let nInterp = Int(t.last! * Self.interpRate)
        guard nInterp >= 64 else { return nil }

        // Linear interpolation to uniform 4 Hz R-R series
        var rrInterp = [Double](repeating: 0, count: nInterp)
        var j = 0
        for i in 0..<nInterp {
            let ti = Double(i) / Self.interpRate
            while j < rr.count - 1 && t[j + 1] < ti { j += 1 }
            let span = t[j + 1] - t[j]
            let nextJ = min(j + 1, rr.count - 1)
            rrInterp[i] = span > 0
                ? rr[j] + (ti - t[j]) / span * (rr[nextJ] - rr[j])
                : rr[j]
        }

        // Zero-pad to FFT size; truncate if longer
        let nFFT = Self.lfhfFFTSize
        var padded: [Double]
        if rrInterp.count >= nFFT {
            padded = Array(rrInterp.prefix(nFFT))
        } else {
            padded = rrInterp + [Double](repeating: 0, count: nFFT - rrInterp.count)
        }

        // Hann window
        var win = [Double](repeating: 0, count: nFFT)
        vDSP_hann_windowD(&win, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))
        vDSP_vmulD(padded, 1, win, 1, &padded, 1, vDSP_Length(nFFT))

        // Real FFT via vDSP — same ctoz trick as EEGPipeline but Double precision
        var realp = [Double](repeating: 0, count: nFFT / 2)
        var imagp = [Double](repeating: 0, count: nFFT / 2)
        padded.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: DSPDoubleComplex.self)
            var split = DSPDoubleSplitComplex(realp: &realp, imagp: &imagp)
            vDSP_ctozD(ptr, 1, &split, 1, vDSP_Length(nFFT / 2))
        }
        let log2N = vDSP_Length(log2(Double(nFFT)).rounded())
        var split = DSPDoubleSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zripD(fftSetup, &split, 1, log2N, FFTDirection(FFT_FORWARD))

        var mag2 = [Double](repeating: 0, count: nFFT / 2)
        vDSP_zvmagsD(&split, 1, &mag2, 1, vDSP_Length(nFFT / 2))

        // Band power: frequency resolution = 4 / 2048 ≈ 0.00195 Hz/bin
        let res = Self.interpRate / Double(nFFT)
        func bandPower(_ lo: Double, _ hi: Double) -> Double {
            let i0 = max(1, Int((lo / res).rounded()))
            let i1 = min(Int((hi / res).rounded()), nFFT / 2 - 1)
            guard i0 <= i1 else { return 0 }
            var sum = 0.0
            mag2.withUnsafeBufferPointer { ptr in
                vDSP_sveD(ptr.baseAddress! + i0, 1, &sum, vDSP_Length(i1 - i0 + 1))
            }
            return sum
        }

        let lf = bandPower(0.04, 0.15)   // sympatho-vagal: 0.04–0.15 Hz
        let hf = bandPower(0.15, 0.40)   // parasympathetic RSA: 0.15–0.40 Hz
        guard hf > 0 else { return nil }
        return lf / hf
    }

    private func median(_ arr: [Double]) -> Double {
        let s = arr.sorted()
        let n = s.count
        return n % 2 == 0 ? (s[n/2 - 1] + s[n/2]) / 2 : s[n/2]
    }

    // MARK: - Poincaré / SDNN (B107)

    static func computeSDNN(_ rr: [Double]) -> Double {
        guard rr.count >= 2 else { return 0 }
        let mean = rr.reduce(0, +) / Double(rr.count)
        let variance = rr.map { pow($0 - mean, 2) }.reduce(0, +) / Double(rr.count)
        return sqrt(variance)
    }

    static func computeSD1(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        let diffs = zip(rr.dropFirst(), rr).map { pow($0 - $1, 2) }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        return rmssd / sqrt(2.0)
    }

    static func computeSD2(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        let sdnn = computeSDNN(rr)
        let diffs = zip(rr.dropFirst(), rr).map { pow($0 - $1, 2) }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        let inner = 2 * pow(sdnn, 2) - pow(rmssd, 2) / 2
        guard inner >= 0 else { return nil }
        return sqrt(inner)
    }
}
