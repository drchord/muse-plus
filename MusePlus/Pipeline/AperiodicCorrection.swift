import Foundation

// Aperiodic-corrected band powers via IRASA (Wen & Liu 2016) + Donoghue/Voytek/Knight 2020 specparam.
//
// Why: meditationIndex = 0.7*((α+θ)-2β) + 0.3*max(0, θ-α) over RAW log-band powers conflates
// oscillatory ("periodic") and 1/f ("aperiodic") activity. Aperiodic shifts during meditation
// (slope steepening: chi -1.4 → -2.0) can mimic α/θ rises without reflecting genuine oscillation
// changes. Subtracting the 1/f estimate at each band's mean frequency yields the true
// oscillatory contribution above the aperiodic floor.
//
// Formula: log10(corrected_band) = log10(raw_band) - aperiodic_at_band_center
//          where aperiodic_at_f = chi * log10(f) + offset (from IRASA fit)
//
// Falls back to raw if R² < 0.85 (already gated upstream by AperiodicSlope.fit).

enum AperiodicCorrection {
    // Geometric mean frequencies used for aperiodic evaluation per band.
    // log10(geo_mean) = mean(log10(lo), log10(hi)) — this matches the band-power
    // computation in EEGPipeline (mean of log10 power across bins in band).
    private static let bandCenter: [String: Float] = [
        "delta": sqrt(1.0 * 4.0),
        "theta": sqrt(4.0 * 8.0),
        "alpha": sqrt(8.0 * 13.0),
        "beta":  sqrt(13.0 * 30.0),
        "gamma": sqrt(30.0 * 50.0),
    ]

    // Apply per-channel correction. Returns BandPowers with periodic-only (above-aperiodic)
    // log power per band. If aperiodicResult is nil (R² gate failed), returns raw bp unchanged.
    static func correct(_ bp: BandPowers, aperiodic: AperiodicResult?) -> BandPowers {
        guard let r = aperiodic else { return bp }
        // aperiodic at frequency f (log10 µV²): r.chi * log10(f) + r.offset
        func ap(_ f: Float) -> Float { r.chi * log10(f) + r.offset }
        return BandPowers(
            delta:     bp.delta - ap(bandCenter["delta"]!),
            theta:     bp.theta - ap(bandCenter["theta"]!),
            alpha:     bp.alpha - ap(bandCenter["alpha"]!),
            beta:      bp.beta  - ap(bandCenter["beta"]!),
            gamma:     bp.gamma - ap(bandCenter["gamma"]!),
            deltaPeak: bp.deltaPeak,
            thetaPeak: bp.thetaPeak,
            alphaPeak: bp.alphaPeak,
            betaPeak:  bp.betaPeak,
            gammaPeak: bp.gammaPeak,
            channel:   bp.channel,
            timestamp: bp.timestamp
        )
    }

    // Apply correction to a list of channels using a single mean-chi/offset estimate.
    // Per-channel aperiodic differs slightly but sharing the mean fit reduces noise
    // and matches how meditationIndex averages across frontal channels anyway.
    static func correct(_ powers: [BandPowers], aperiodic: AperiodicResult?) -> [BandPowers] {
        guard let r = aperiodic else { return powers }
        return powers.map { correct($0, aperiodic: r) }
    }
}
