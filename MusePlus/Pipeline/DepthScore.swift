import Foundation

final class DepthScore {
    static let calibrationDuration: TimeInterval = 60.0
    // Frontal channels (AF7=1, AF8=2) are most reliable for meditation alpha/theta
    private static let frontalChannels = [1, 2]

    private var calibrationStart: Date?
    private var calibrationSamples: [Float] = []
    private var baselineMean: Float = 0
    private var baselineStd: Float  = 1

    var isCalibrated: Bool {
        guard let start = calibrationStart else { return false }
        return Date().timeIntervalSince(start) >= DepthScore.calibrationDuration
    }

    var calibrationProgress: Float {
        guard let start = calibrationStart else { return 0 }
        return min(Float(Date().timeIntervalSince(start) / DepthScore.calibrationDuration), 1.0)
    }

    var onResult: ((DepthResult) -> Void)?

    func startCalibration() {
        calibrationStart  = Date()
        calibrationSamples = []
        baselineMean = 0
        baselineStd  = 1
    }

    func process(_ powers: [BandPowers]) {
        let frontal = powers.filter { DepthScore.frontalChannels.contains($0.channel) }
        guard !frontal.isEmpty else { return }

        // meditationIndex = alpha_log - beta_log per frontal channel, then average
        let idx = frontal.map(\.meditationIndex).reduce(0, +) / Float(frontal.count)

        let progress = calibrationProgress

        if !isCalibrated {
            calibrationSamples.append(idx)
            onResult?(DepthResult(score: 0.5, isCalibrated: false, calibrationProgress: progress))
            return
        }

        // Finalize baseline on first calibrated call
        if calibrationSamples.isEmpty == false {
            finalizeBaseline()
        }

        // Normalize: how many std-devs above baseline?
        let z = (idx - baselineMean) / max(baselineStd, 0.01)
        let score = sigmoid(z)

        onResult?(DepthResult(score: score, isCalibrated: true, calibrationProgress: 1.0))
    }

    private func finalizeBaseline() {
        guard !calibrationSamples.isEmpty else { return }
        let n = Float(calibrationSamples.count)
        let mean = calibrationSamples.reduce(0, +) / n
        let variance = calibrationSamples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        baselineMean = mean
        baselineStd  = sqrt(variance)
        calibrationSamples = []
    }

    private func sigmoid(_ x: Float) -> Float {
        1.0 / (1.0 + exp(-x))
    }
}
