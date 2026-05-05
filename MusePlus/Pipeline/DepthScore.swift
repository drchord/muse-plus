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

        let idx = frontal.map(\.meditationIndex).reduce(0, +) / Float(frontal.count)

        // FAA = AF8 alpha - AF7 alpha (positive = right frontal dominant = approach/positive affect)
        let af7Alpha = powers.first(where: { $0.channel == 1 })?.alpha ?? 0
        let af8Alpha = powers.first(where: { $0.channel == 2 })?.alpha ?? 0
        let faa = af8Alpha - af7Alpha

        let progress = calibrationProgress

        if !isCalibrated {
            calibrationSamples.append(idx)
            onResult?(DepthResult(score: 0.5, isCalibrated: false,
                                  calibrationProgress: progress, faa: faa))
            return
        }

        if !calibrationSamples.isEmpty {
            finalizeBaseline()
        }

        let z = (idx - baselineMean) / max(baselineStd, 0.01)
        let score = sigmoid(z)

        onResult?(DepthResult(score: score, isCalibrated: true,
                              calibrationProgress: 1.0, faa: faa))
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
