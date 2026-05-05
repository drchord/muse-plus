import Accelerate
import Foundation

// Individual Theta Peak Frequency tracker.
// Gaussian fit via log-parabola interpolation (Corcoran AW et al 2018 NeuroImage 174:245).
// Cross-session Kalman aggregation (Cesnaite E et al 2023 J Neurosci 43:4143).
// Klimesch W 1999 Brain Res Rev 29:169 — inter-individual theta peak range: 5.5–7.5 Hz.
final class ITPFTracker {

    private struct KalmanState: Codable {
        var estimate: Float     // current iTPF estimate, Hz
        var variance: Float     // Kalman P (uncertainty)
        var sessionCount: Int   // distinct sessions contributed
        var cleanMinutes: Float // cumulative clean frontal minutes (all-time)
    }

    private static let stateKey       = "itpf.kalman.state"
    private static let processNoiseKey = "itpf.kalman.Q"

    private var state: KalmanState
    private var processNoise: Float         // Q — adapted from within-session measurement spread
    private let measurementNoise: Float = 0.25  // R — ~0.5 Hz std on log-parabola estimates²

    private var sessionMeasurements = [Float]()

    private(set) var currentEstimate: Float?  // nil until reliability gate passes

    var isReliable: Bool {
        state.sessionCount >= 3 && state.cleanMinutes >= 10.0
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let s = try? JSONDecoder().decode(KalmanState.self, from: data) {
            state = s
        } else {
            state = KalmanState(estimate: 6.0, variance: 1.0, sessionCount: 0, cleanMinutes: 0)
        }
        let q = UserDefaults.standard.float(forKey: Self.processNoiseKey)
        processNoise = q > 0 ? q : 0.01
        currentEstimate = isReliable ? state.estimate : nil
    }

    // Called every clean 2s window (artifact-suppressed windows are skipped by EEGPipeline).
    // af7PSD, af8PSD: one-sided mag2 PSD (windowSize/2 bins).
    func update(af7PSD: [Float], af8PSD: [Float], sampleRate: Float, windowSize: Int) {
        let binHz = sampleRate / Float(windowSize)
        let n = min(af7PSD.count, af8PSD.count)
        guard n > 0 else { return }

        // Average AF7 + AF8 for frontal SNR
        var meanPSD = [Float](repeating: 0, count: n)
        vDSP_vadd(af7PSD, 1, af8PSD, 1, &meanPSD, 1, vDSP_Length(n))
        var half: Float = 0.5
        vDSP_vsmul(meanPSD, 1, &half, &meanPSD, 1, vDSP_Length(n))

        // Theta band: 4–8 Hz
        let lo = max(1, Int((4.0 / binHz).rounded()))
        let hi = min(Int((8.0 / binHz).rounded()), n - 1)
        guard hi > lo + 2 else { return }

        // Argmax within theta band
        var maxVal: Float = 0
        var peakOff: vDSP_Length = 0
        meanPSD.withUnsafeBufferPointer { ptr in
            vDSP_maxvi(ptr.baseAddress! + lo, 1, &maxVal, &peakOff, vDSP_Length(hi - lo + 1))
        }
        let peakBin = lo + Int(peakOff)
        guard peakBin > lo && peakBin < hi else { return }

        // Log-parabola interpolation — equivalent to Gaussian fit in log-power domain.
        // Quinn 1994 / Corcoran 2018: offset = (p[k-1] - p[k+1]) / (2*(p[k-1] - 2*p[k] + p[k+1]))
        let p0 = log(max(meanPSD[peakBin - 1], 1e-30))
        let p1 = log(max(meanPSD[peakBin],     1e-30))
        let p2 = log(max(meanPSD[peakBin + 1], 1e-30))
        let denom = p0 - 2 * p1 + p2
        guard abs(denom) > 1e-6 else { return }
        let interpOffset = 0.5 * (p0 - p2) / denom
        let peakFreq = (Float(peakBin) + interpOffset) * binHz
        guard peakFreq >= 4.0 && peakFreq <= 8.0 else { return }

        // Kalman update (prediction + correction)
        let pPred = state.variance + processNoise
        let K = pPred / (pPred + measurementNoise)
        state.estimate += K * (peakFreq - state.estimate)
        state.variance = (1 - K) * pPred
        state.cleanMinutes += 2.0 / 60.0

        sessionMeasurements.append(peakFreq)
        currentEstimate = isReliable ? state.estimate : nil
    }

    // Call at session end to persist Kalman state and adapt process noise from
    // within-session iTPF spread (slow within-session drift → larger Q → faster tracking).
    func endSession() {
        state.sessionCount += 1
        if sessionMeasurements.count > 5 {
            let mean = sessionMeasurements.reduce(0, +) / Float(sessionMeasurements.count)
            let variance = sessionMeasurements.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                           / Float(sessionMeasurements.count)
            processNoise = max(0.005, variance * 0.1)
        }
        persist()
        sessionMeasurements.removeAll()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
        UserDefaults.standard.set(processNoise, forKey: Self.processNoiseKey)
    }
}
