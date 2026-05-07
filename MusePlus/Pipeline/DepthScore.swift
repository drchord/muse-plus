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

    func process(_ powers: [BandPowers], correctedPowers: [BandPowers]? = nil) {
        let frontal = powers.filter { DepthScore.frontalChannels.contains($0.channel) }
        guard !frontal.isEmpty else { return }

        // Raw uncorrected index (legacy / diagnostic).
        let idxRaw = frontal.map(\.meditationIndex).reduce(0, +) / Float(frontal.count)

        // Aperiodic-corrected index when available (B77+). Falls back to raw if R²<0.85
        // gate upstream returned nil (correctedPowers == nil) or chi unavailable.
        // Donoghue 2020: 1/f-corrected band power isolates true oscillatory contribution
        // above the broadband aperiodic floor.
        let idxCorrected: Float
        if let cp = correctedPowers {
            let cf = cp.filter { DepthScore.frontalChannels.contains($0.channel) }
            idxCorrected = cf.isEmpty ? idxRaw
                : cf.map(\.meditationIndex).reduce(0, +) / Float(cf.count)
        } else {
            idxCorrected = idxRaw
        }

        // Aperiodic correction toggle — ON by default. The correction's global shift in
        // idx (≈chi * log10((α_f*θ_f)/β_f²) ≈ -1.2 with chi=-1.5) cancels in the z-score
        // since calibration baseline shifts by the same amount. But: chi may change with
        // depth, amplifying within-session z gap. Personal ECDF renormalizes this in the
        // modern track (after 3 sessions). For users whose first B77 session saturates,
        // toggle this OFF in Settings to scoring against raw idx.
        let useCorrection = UserDefaults.standard.object(forKey: "aperiodicCorrectionEnabled") as? Bool ?? true
        let idx = useCorrection ? idxCorrected : idxRaw

        let af7Alpha = powers.first(where: { $0.channel == 1 })?.alpha ?? 0
        let af8Alpha = powers.first(where: { $0.channel == 2 })?.alpha ?? 0
        let faa = af8Alpha - af7Alpha

        let progress = calibrationProgress

        if !isCalibrated {
            calibrationAllSamples.append(idx)
            // Discard first 30s of 60s calibration. Alpha/theta stabilise within ~30s of
            // eyes-closed rest (Oken et al. 2006); early samples carry elevated beta from
            // headband adjustment, biasing z positive.
            if progress >= 0.5 {
                calibrationSamples.append(idx)
                let frontalBeta = frontal.map(\.beta).reduce(0, +) / Float(frontal.count)
                calibrationBetaSamplesInternal.append(frontalBeta)
            }
            onResult?(DepthResult(score: 0.5, z: 0, meditationIndex: idxRaw,
                                  meditationIndexCorrected: idxCorrected,
                                  isCalibrated: false, calibrationProgress: progress, faa: faa))
            return
        }

        if !calibrationSamples.isEmpty {
            finalizeBaseline()
        }

        // Z-clip [-3, +8]. Lower clip prevents noise artifacts from over-suppressing.
        // Upper +8 restored in B77 — was removed in B75 but caused unbounded sigmoid
        // saturation. +8 is well above any plausible physiological signal (B76 p99=7.81).
        // Personal ECDF saturates near +7 anyway so clip at +8 is functionally invisible.
        let z = max(-3.0, min(8.0, (idx - baselineMean) / max(baselineStd, 0.01)))
        let score = sigmoid(z)  // legacy field; ECDF display uses z directly via PersonalZDistribution

        onResult?(DepthResult(score: score, z: z, meditationIndex: idxRaw,
                              meditationIndexCorrected: idxCorrected,
                              isCalibrated: true, calibrationProgress: 1.0, faa: faa))
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
