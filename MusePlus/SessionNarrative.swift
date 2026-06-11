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
        // Threshold below which within-calibration beta variance is classified as "quiet".
        // Provisional: no documented empirical basis. Treat as signal, not gate. Revisit at n=50.
        let quietCalibBetaStdThreshold: Float = 0.12
        if let std = r.calibrationBetaStd, std <= quietCalibBetaStdThreshold {
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
        // No entry. Show personal-history percentile and gap to threshold.
        if let m = r.ecdfMax {
            let myPct     = Int((m * 100).rounded())
            let thresh    = r.enterThresholdAtSession ?? 0.70
            let threshPct = Int((thresh * 100).rounded())
            let gap       = threshPct - myPct
            if gap <= 3 {
                return "Your best depth today was at the \(myPct)th percentile of your personal history — just \(gap) point\(gap == 1 ? "" : "s") below the \(threshPct)th-percentile gate. The gate requires \(secStr) seconds sustained above it."
            }
            return "Your best depth today was at the \(myPct)th percentile of your personal history — \(gap) points below the \(threshPct)th-percentile gate. The gate requires \(secStr) seconds sustained."
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
        // B137: build-change caveat — depth ECDF is calibration-relative and not cross-build
        // comparable. Fires once on the first session after an app upgrade.
        if let prev = r.previousBuildTag, let cur = r.buildTag, prev != cur {
            return "Note: app updated \(prev) → \(cur). Depth scores use a personal ECDF baseline — direct comparison with prior sessions may not be valid until a few sessions recalibrate the baseline."
        }
        // Priority: gate close-call > low readiness > calibration weak > artifact > steady state
        let deepF = r.deepFraction ?? 0
        if deepF == 0, let m = r.ecdfMax, m >= 0.80 {
            return "Insight: you are at the edge — keep the same approach and the gate will yield."
        }
        // B135: low readiness score with specific dominant factor
        if deepF == 0, let rs = r.readinessScore, rs <= 2 {
            if let f = r.warmupFAAMean, f >= 0 {
                return "Insight: warmup FAA was positive (\(String(format: "+%.2f", f))) — left-frontal arousal pattern. Right-dominant FAA predicts depth for you. Try sitting still for 2 extra minutes before starting."
            }
            if let s = r.warmupAperiodicSlopeMean, s < -1.35 {
                return "Insight: pre-session brain noise was elevated (slope \(String(format: "%.2f", s))). The brain was not in a low-arousal resting state at start. Earlier sleep and no screens 30 min before may shift this."
            }
        }
        // B137: mixed readiness with zero depth — one or two warmup indicators misaligned.
        // Check physioCard for which specific factor was limiting.
        if deepF == 0, let rs = r.readinessScore, rs >= 3, rs <= 4 {
            let limit: String
            if let f = r.warmupFAAMean, f >= 0 {
                limit = "FAA was positive (\(String(format: "+%.2f", f))) — the key factor to shift"
            } else if let s = r.warmupAperiodicSlopeMean, s < -1.35 {
                limit = "pre-session slope was steep (\(String(format: "%.2f", s))) — brain noise floor was high"
            } else {
                limit = "check physioCard for the limiting factor"
            }
            return "Insight: mixed readiness (\(rs)/6) — conditions were partially aligned. \(limit). One extra minute of slow exhale breathing before starting often shifts the balance."
        }
        if r.calibrationBetaAttached == false {
            return "Insight: settle for one extra minute before tapping start so calibration can lock."
        }
        if let spikes = r.signalQualityMeanSpikes, spikes >= 20 {
            return "Insight: reposition the headband and check ear contact next session."
        }
        // B137: shallow session with elevated beta — name the limiter.
        if deepF < 0.15, let beta = r.betaRelMean, beta > 0.24 {
            return "Insight: beta was elevated (\(String(format: "%.3f", beta))) — active mental processing may have been the ceiling. Try a body scan or open-monitoring practice tomorrow to reduce directed attention."
        }
        if deepF > 0.30 {
            // B135: note high readiness when depth is confirmed
            if let rs = r.readinessScore, rs >= 5 {
                return "Insight: readiness score was \(rs)/6 — all three warmup indicators aligned. Note what felt different at the start of this session."
            }
            return "Insight: this is a reproducible state for you now — same time, same setup, next session."
        }
        return "Insight: stay with the same practice; depth grows on its own timeline."
    }
}
