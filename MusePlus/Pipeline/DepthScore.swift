import Foundation

final class DepthScore {
    static let calibrationDuration: TimeInterval = 60.0
    private static let frontalChannels = [1, 2]

    private var calibrationStart: Date?
    private var calibrationSamples: [Float] = []
    private var calibrationBetaSamplesInternal: [Float] = []
    // Raw fallback samples: all windows, including the discarded first-30s transient.
    // Used only if the settled window yields zero samples (sub-1Hz delivery — extremely rare).
    private var calibrationAllSamples: [Float] = []
    private var baselineMean: Float = 0
    private var baselineStd:  Float = 1

    // Exposed for Settings diagnostics — lets user verify calibration quality.
    // baselineStd < 0.10 means calibration was extremely stable (or artifacted).
    // baselineStd > 0.35 means high variability — consider recalibrating.
    private(set) var calibrationIndexMean: Float = 0
    private(set) var calibrationIndexStd:  Float = 0

    private(set) var calibrationBetaMean: Float = 0
    private(set) var calibrationBetaStd:  Float = 0.30

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
        calibrationStart               = Date()
        calibrationSamples             = []
        calibrationBetaSamplesInternal = []
        calibrationAllSamples          = []
        baselineMean           = 0
        baselineStd            = 1
        calibrationIndexMean   = 0
        calibrationIndexStd    = 0
        calibrationBetaMean    = 0
        calibrationBetaStd     = 0.30
    }

    func process(_ powers: [BandPowers]) {
        let frontal = powers.filter { DepthScore.frontalChannels.contains($0.channel) }
        guard !frontal.isEmpty else { return }

        let idx = frontal.map(\.meditationIndex).reduce(0, +) / Float(frontal.count)

        let af7Alpha = powers.first(where: { $0.channel == 1 })?.alpha ?? 0
        let af8Alpha = powers.first(where: { $0.channel == 2 })?.alpha ?? 0
        let faa = af8Alpha - af7Alpha

        let progress = calibrationProgress

        if !isCalibrated {
            // Always accumulate all samples for fallback.
            calibrationAllSamples.append(idx)
            // Discard first half of the calibration window (first 30s of 60s).
            // Time-based: robust at any band-powers delivery rate, unlike count-based.
            // Alpha/theta stabilise within ~30s of eyes-closed rest (Oken et al. 2006);
            // early samples carry elevated beta from headband adjustment, biasing z positive.
            if progress >= 0.5 {
                calibrationSamples.append(idx)
                let frontalBeta = frontal.map(\.beta).reduce(0, +) / Float(frontal.count)
                calibrationBetaSamplesInternal.append(frontalBeta)
            }
            onResult?(DepthResult(score: 0.5, isCalibrated: false,
                                  calibrationProgress: progress, faa: faa))
            return
        }

        if !calibrationSamples.isEmpty {
            finalizeBaseline()
        }

        // Floor z at -3: prevents noise artifacts mapping to near-zero score.
        // No upper clip: sigmoid is asymptotically bounded at 1.0; removing the +3 clip
        // restores resolution for the 38% of real-session samples that were saturating
        // at sigmoid(3)=0.9526, making the entire upper range visually indistinguishable.
        // baselineStd floored to 0.01 as safety net only — real floor in finalizeBaseline().
        let z = max(-3.0, (idx - baselineMean) / max(baselineStd, 0.01))
        let score = sigmoid(z)

        onResult?(DepthResult(score: score, isCalibrated: true,
                              calibrationProgress: 1.0, faa: faa))
    }

    private func finalizeBaseline() {
        // Fallback: if band powers arrived slower than 2Hz and no samples cleared the
        // 30s threshold, use all collected samples rather than leaving baselineMean=0.
        if calibrationSamples.isEmpty && !calibrationAllSamples.isEmpty {
            calibrationSamples = calibrationAllSamples
        }
        guard !calibrationSamples.isEmpty else { return }
        calibrationAllSamples = []
        let n = calibrationSamples.count

        // Robust estimation: median + MAD instead of mean + sample std.
        // Resistant to movement-artifact outliers during the calibration window.
        // MAD × 1.4826 = consistent Gaussian σ estimate.
        let sorted = calibrationSamples.sorted()
        let median: Float = n % 2 == 0
            ? (sorted[n/2 - 1] + sorted[n/2]) / 2
            : sorted[n/2]
        baselineMean = median

        let absDevs = calibrationSamples.map { abs($0 - median) }.sorted()
        let mad: Float = n % 2 == 0
            ? (absDevs[n/2 - 1] + absDevs[n/2]) / 2
            : absDevs[n/2]
        // Floor at 0.10 log10(µV²): below this, calibration was unusually stable
        // and z-scores become hypersensitive to small EEG fluctuations.
        // 0.10 means a 0.10-unit shift in meditationIndex gives z=1 → score=0.73.
        // This floor is provisional — check calibrationIndexStd in Settings after
        // a few sessions to determine whether 0.10 is appropriate for your EEG.
        baselineStd = max(mad * 1.4826, 0.10)

        calibrationIndexMean = baselineMean
        calibrationIndexStd  = baselineStd
        calibrationSamples   = []

        if !calibrationBetaSamplesInternal.isEmpty {
            let nb = Float(calibrationBetaSamplesInternal.count)
            let bm = calibrationBetaSamplesInternal.reduce(0, +) / nb
            let bv = calibrationBetaSamplesInternal.map { ($0 - bm) * ($0 - bm) }.reduce(0, +) / nb
            calibrationBetaMean = bm
            calibrationBetaStd  = max(0.10, sqrt(bv))
            calibrationBetaSamplesInternal = []
        }
    }

    private func sigmoid(_ x: Float) -> Float {
        1.0 / (1.0 + exp(-x))
    }
}
