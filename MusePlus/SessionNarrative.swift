import Foundation

/// B126 — plain-English session narrative composer.
///
/// Pure-Swift, deterministic, no Date/AVAudioEngine/Muse SDK. Reads from SessionRecord only
/// (which has been populated from NDJSONFooter via attachFooter at session end).
///
/// Output: ordered list of 3-5 lines, each a complete sentence in the second person, no
/// jargon, no raw decimals. Designed to be displayed in SessionSummarySheet directly above
/// the existing "Insight" line.
///
/// Six dimensions in fixed order:
///   1. Calibration quality
///   2. Gate outcome (entered? approached? how close?)
///   3. Signal quality
///   4. Physiology (RMSSD / HRV summary)
///   5. Alpha-theta crossover
///   6. One actionable insight
///
/// Any dimension whose inputs are nil is silently skipped (no "data unavailable" filler).
struct SessionNarrative {
    let lines: [String]

    static func compose(from r: SessionRecord) -> SessionNarrative {
        var out: [String] = []

        // 1. Calibration
        if let cal = calibrationLine(r) { out.append(cal) }

        // 2. Gate outcome (highest-impact line; ALWAYS present)
        out.append(gateLine(r))

        // 3. Signal quality
        if let sig = signalLine(r) { out.append(sig) }

        // 4. Physiology
        if let phys = physiologyLine(r) { out.append(phys) }

        // 5. Crossover
        if let xo = crossoverLine(r) { out.append(xo) }

        // 6. Insight (always present)
        out.append(insightLine(r))

        return SessionNarrative(lines: out)
    }

    // MARK: - Dimensions

    private static func calibrationLine(_ r: SessionRecord) -> String? {
        guard let attached = r.calibrationBetaAttached else { return nil }
        if attached == false {
            return "Your calibration was incomplete — your headband or your stillness may not have settled in time."
        }
        // 0.12: conservative threshold below which within-calibration beta variance is
        // classified as "quiet". Origin undocumented — needs empirical validation against
        // session corpus before this branch is trusted.
        if let std = r.calibrationBetaStd, std <= 0.12 {
            return "Your calibration was strong today — your brain quieted well before meditation began."
        }
        return "Your calibration completed normally."
    }

    private static func gateLine(_ r: SessionRecord) -> String {
        let secs = r.enterSustainedAtSession.map { Double($0) * 0.5 }
                   ?? Double(EnterSustainedShaping.currentWindows()) * 0.5
        let secStr = secs == floor(secs) ? "\(Int(secs))" : String(format: "%.1f", secs)
        let deepF = r.deepFraction ?? 0
        if deepF > 0.15 {
            return "You held the deep state for a meaningful share of the session — the gate currently requires \(secStr) seconds of sustained focus."
        }
        if deepF > 0 {
            return "You touched the deep state briefly today — the gate currently requires \(secStr) seconds of sustained focus."
        }
        // No entry. Reach for ecdfMax if present.
        if let m = r.ecdfMax {
            let pct = Int((m * 100).rounded())
            if pct >= 80 {
                return "You came very close to deep state — your peak depth was \(pct)% of what's needed. The gate currently requires \(secStr) seconds of sustained focus."
            }
            return "You reached about \(pct)% of the depth needed for entry. The gate currently requires \(secStr) seconds of sustained focus."
        }
        return "You did not reach deep state today. The gate currently requires \(secStr) seconds of sustained focus."
    }

    private static func signalLine(_ r: SessionRecord) -> String? {
        guard let spikes = r.signalQualityMeanSpikes else { return nil }
        if spikes < 8 {
            return "Signal was clean throughout — no significant artifact spikes detected."
        }
        if spikes < 20 {
            return "Signal was generally good with occasional artifact spikes."
        }
        return "Signal showed elevated artifact today — try repositioning the headband next session."
    }

    private static func physiologyLine(_ r: SessionRecord) -> String? {
        guard let rmssd = r.rmssd, let calR = r.calibrationRmssd else { return nil }
        let delta = rmssd - calR
        if delta >  3 { return "Your heart-rate variability rose during meditation — a strong autonomic relaxation response." }
        if delta < -3 { return "Your heart-rate variability dropped slightly during meditation — possibly active processing rather than rest." }
        return "Your heart-rate variability stayed steady through the session."
    }

    private static func crossoverLine(_ r: SessionRecord) -> String? {
        guard let n = r.alphaThetaCrossoverCount, n > 0 else { return nil }
        if let first = r.alphaThetaCrossoverFirstTime {
            let mins = Int(first / 60)
            if n >= 5 {
                return "Your theta exceeded alpha \(n) times today — your brain reached for deep state from about \(mins) minutes in."
            }
            return "Your theta exceeded alpha \(n) time\(n == 1 ? "" : "s") today, first around \(mins) minutes in."
        }
        return "Your theta exceeded alpha \(n) time\(n == 1 ? "" : "s") today."
    }

    private static func insightLine(_ r: SessionRecord) -> String {
        // Priority: gate close-call > calibration weak > artifact > steady state
        let deepF = r.deepFraction ?? 0
        if deepF == 0, let m = r.ecdfMax, m >= 0.80 {
            return "Insight: you are at the edge — keep the same approach and the gate will yield."
        }
        if r.calibrationBetaAttached == false {
            return "Insight: settle for one extra minute before tapping start so calibration can lock."
        }
        if let spikes = r.signalQualityMeanSpikes, spikes >= 20 {
            return "Insight: reposition the headband and check ear contact next session."
        }
        if deepF > 0.30 {
            return "Insight: this is a reproducible state for you now — same time, same setup, next session."
        }
        return "Insight: stay with the same practice; depth grows on its own timeline."
    }
}
