import Foundation

// Personal ECDF lookup table over historical depth z-scores.
// Replaces sigmoid(z) as the user-facing display map.
//
// Why ECDF over sigmoid: sigmoid asymptotes near z>3, crushing all "deep" states
// to 0.95-0.999. A user who reaches z=3-7 routinely (Sugato's pooled p10-p90 range)
// has effectively no display resolution. ECDF gives uniform output by construction
// (Probability Integral Transform) → gauge actually uses full 0-100% range.
//
// Implementation: 21-point breakpoint LUT (every 5%). Linear interpolation between.
// Storage cost: 21 floats = 84 bytes. Lookup: O(log n) on n=21 → effectively O(1).
//
// Two-track design:
//   - bootstrap: B76 distribution (n=4116, single uncorrected formula). Always present.
//   - modern:    B77+ aperiodic-corrected sessions. Becomes authoritative at N>=3.
//
// Muse SDK validation: Muse's own Elements algorithm computes "session score" by
// linearly mapping current band power to [0,1] via p10/p90 of recent history.
// That's a 2-anchor ECDF — special case of this 21-anchor approach.

final class PersonalZDistribution {
    static let shared = PersonalZDistribution()

    // 21 breakpoints at percentiles 0, 5, 10, ..., 95, 100.
    // Bootstrap from B76 session_2026-05-07_0354.json (n=4116, uncorrected formula).
    // Index 20 (p100) clipped at 8.0 to match DepthScore upper z-clip.
    static let bootstrapBreakpoints: [Float] = [
        -0.7478, 2.4095, 2.9508, 3.3775, 3.6620, 3.9317, 4.1654, 4.3806,
         4.5671, 4.7590, 4.9579, 5.1457, 5.3356, 5.5228, 5.7291, 5.9332,
         6.1829, 6.4592, 6.8064, 7.3538, 8.0000
    ]

    private static let bootstrapKey  = "personalZBootstrap"
    private static let modernKey     = "personalZModern"
    private static let modernCountKey = "personalZModernSessionCount"
    private static let trackKey      = "personalZTrack"  // "bootstrap" | "modern"

    // Switchover threshold: B77+ sessions before modern track becomes authoritative.
    // Set to 1 because the bootstrap LUT was built from B76 RAW idx (uncorrected),
    // but B77 uses aperiodic-corrected idx by default. The two distributions are
    // categorically different — bootstrap p50=3.20 vs B77 z typically ~0. Bootstrap
    // would force first session to display near 0% the entire time. Activating modern
    // at session 1 means the first session establishes the personal distribution and
    // session 2+ display against it. EMA-blend in ingestSession adapts gradually.
    private static let modernActivationCount = 1

    private var breakpoints: [Float]
    private(set) var sessionCount: Int = 0
    private(set) var trackName: String = "bootstrap"

    // Within-session rolling ring for cold-start. When sessionCount == 0 (no personal
    // data yet) the bootstrap LUT was built from B76 RAW idx and is categorically wrong
    // for B77 corrected idx — gauge would read ~0% the whole first session. The ring
    // provides within-session percentile ranking from second 1 of the first session.
    // Capacity 600 = 5 minutes at 2 Hz. Updated in lockstep with ecdf() calls.
    private static let coldStartRingCapacity = 600
    private var coldStartRing      = [Float](repeating: 0, count: coldStartRingCapacity)
    private var coldStartRingHead  = 0
    private var coldStartRingFilled = 0
    private static let coldStartMinSamples = 30  // need ~15s of data before within-session ECDF is meaningful

    func resetSessionRing() {
        coldStartRingHead = 0
        coldStartRingFilled = 0
    }

    private init() {
        let defaults = UserDefaults.standard
        sessionCount = defaults.integer(forKey: Self.modernCountKey)

        if let stored = defaults.array(forKey: Self.modernKey) as? [Double],
           stored.count == 21,
           sessionCount >= Self.modernActivationCount {
            breakpoints = stored.map(Float.init)
            trackName = "modern"
        } else if let stored = defaults.array(forKey: Self.bootstrapKey) as? [Double],
                  stored.count == 21 {
            breakpoints = stored.map(Float.init)
            trackName = "bootstrap-stored"
        } else {
            breakpoints = Self.bootstrapBreakpoints
            trackName = "bootstrap-default"
            // Persist defaults so they're inspectable.
            defaults.set(Self.bootstrapBreakpoints.map(Double.init), forKey: Self.bootstrapKey)
        }
    }

    // ECDF lookup. Returns [0, 1].
    // For users with personal data (sessionCount >= 1): linear interp on personal LUT.
    // For first session (sessionCount == 0): within-session percentile rank using the
    // rolling ring — this prevents the bootstrap-mismatch problem where B77 corrected z
    // values fall outside the B76-raw bootstrap range.
    func ecdf(_ z: Float) -> Float {
        // Always feed the ring so cold-start has data even if personal LUT is in use.
        if z.isFinite {
            coldStartRing[coldStartRingHead] = z
            coldStartRingHead = (coldStartRingHead + 1) % Self.coldStartRingCapacity
            coldStartRingFilled = min(coldStartRingFilled + 1, Self.coldStartRingCapacity)
        }

        // Cold-start path: within-session percentile rank.
        if sessionCount == 0 && coldStartRingFilled >= Self.coldStartMinSamples {
            var below = 0
            for i in 0..<coldStartRingFilled {
                if coldStartRing[i] <= z { below += 1 }
            }
            return Float(below) / Float(coldStartRingFilled)
        }

        // Normal path: personal LUT lookup.
        if z <= breakpoints[0] { return 0 }
        if z >= breakpoints[20] { return 1 }
        for i in 1...20 {
            if z <= breakpoints[i] {
                let span = breakpoints[i] - breakpoints[i-1]
                let frac: Float = span > 0 ? (z - breakpoints[i-1]) / span : 0
                return (Float(i-1) + frac) / 20.0
            }
        }
        return 1
    }

    // Inverse lookup: percentile rank → z value. Used by DepthGate to convert
    // ECDF-space thresholds (e.g., 0.70) back to z thresholds for raw comparisons.
    func zAtPercentile(_ p: Float) -> Float {
        let clamped = max(0, min(1, p))
        let scaled = clamped * 20.0
        let lo = Int(scaled.rounded(.down))
        let hi = min(lo + 1, 20)
        let frac = scaled - Float(lo)
        return breakpoints[lo] * (1 - frac) + breakpoints[hi] * frac
    }

    // Expose breakpoints for diagnostics UI.
    func percentile(_ idx: Int) -> Float {
        guard (0...20).contains(idx) else { return 0 }
        return breakpoints[idx]
    }

    var p5:  Float { breakpoints[1] }
    var p50: Float { breakpoints[10] }
    var p95: Float { breakpoints[19] }

    // Update modern-track LUT after a session ends.
    // zSamples: all valid z values from the just-ended session (typically ~3500).
    // Strategy: weighted merge with prior modern breakpoints.
    //   - On 1st modern session: just compute breakpoints from samples.
    //   - On 2nd+: 70/30 blend of new session vs running. Reservoir-style without
    //     storing all raw samples (would grow unbounded).
    func ingestSession(zSamples: [Float]) {
        let valid = zSamples.filter { $0.isFinite }
        guard valid.count >= 100 else { return }  // need enough for stable percentiles

        let sorted = valid.sorted()
        let newBreakpoints: [Float] = (0...20).map { i in
            let idx = Int(Float(i) / 20.0 * Float(sorted.count - 1))
            return min(8.0, sorted[max(0, min(sorted.count - 1, idx))])
        }

        let defaults = UserDefaults.standard
        sessionCount += 1
        defaults.set(sessionCount, forKey: Self.modernCountKey)

        var merged: [Float]
        if let stored = defaults.array(forKey: Self.modernKey) as? [Double],
           stored.count == 21,
           sessionCount > 1 {
            let prior = stored.map(Float.init)
            // EMA-style blend: 30% new, 70% prior. Smooth adaptation; one anomalous session
            // (e.g., poor headband fit) shifts the LUT only modestly.
            merged = (0...20).map { 0.7 * prior[$0] + 0.3 * newBreakpoints[$0] }
        } else {
            merged = newBreakpoints
        }

        defaults.set(merged.map(Double.init), forKey: Self.modernKey)

        // Activate modern track once threshold reached.
        if sessionCount >= Self.modernActivationCount {
            breakpoints = merged
            trackName = "modern"
        }
    }

    // Reset for testing/recovery. Does not delete — restores defaults.
    func resetToBootstrap() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.modernKey)
        defaults.removeObject(forKey: Self.modernCountKey)
        sessionCount = 0
        breakpoints = Self.bootstrapBreakpoints
        trackName = "bootstrap-default"
    }
}
