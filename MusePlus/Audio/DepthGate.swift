import Foundation

// MARK: - Tuning constants (file-level, never change per-instance)

// Score must hold above/below threshold for this many 0.5s windows before chiming.
// B126: kEnterSustained is now an instance var re-read at every reset() so shaping changes
// (written by EnterSustainedShaping.recordSession at session end) take effect on the NEXT session
// without requiring an app relaunch. Within a session this value is never mutated.
// Default 12 (6s). Range [4, 20]. Managed by EnterSustainedShaping.
private let kExitSustained:  Int    = 20
// Minimum gap between two enter/exit chimes (same direction).
private let kCooldown: TimeInterval = 90   // 1.5 minutes
// EMA alpha for smoothedScore (sigmoid-space legacy). smoothedDisplay now uses Kalman (B94).
private let kEmaAlpha: Float        = 0.20
// B94: duck gain uses separate slower smoother (tau≈5s) to prevent audible volume pumping.
// Empirical: 76% fewer approach-zone threshold crossings vs raw smoothedDisplay.
private let kDuckAlpha: Float       = 0.095
// Conditioning anchor delay: 20s after confirmed deep entry.
// Justified: enter chime ducks soundscape for 4.5s then 1.5s unduck → audio restored at ~6s.
// 20s total = 14s of silence after unduck before anchor fires.
// The 10s hysteresis window (kEnterSustained) already guarantees 10s above threshold to enter.
// So anchor fires when user has been above threshold for 30s total — genuine deep, not transient.
private let kAnchorDelay: TimeInterval  = 20.0
// Cross-episode anchor cooldown: 5 minutes.
// Justified: enough time for the brain to re-enter a distinct state transition (not rapid cycling);
// avoids flooding within a single multi-entry session (max ~4 anchors per 20-min session).
private let kAnchorCooldown: TimeInterval = 300.0

// Anchor crossing threshold: re-fires when display ECDF rank crosses INTO the top 10%
// of personal history. Allows multiple Pavlovian-conditioning trials per session for users
// who maintain deep state continuously (rather than the B76 degenerate single-fire behavior
// where 100% inDeep produced exactly one anchor for the entire 56-min session).
private let kAnchorEcdfThreshold: Float = 0.90

// B77: "going deeper" gentle chime — fires when within-deep ECDF display rises by
// kDeepeningDelta or more over kDeepeningWindow seconds. Cooldown kDeepeningCooldown
// prevents over-firing during sustained ascents.
//
// Why rate-based instead of threshold-based: for a user pegged near 1.0 ECDF the entire
// session, no absolute threshold can distinguish "going deeper" from "already deep."
// Tracking rate-of-change over a 30s window detects relative ascents within the deep band.
//
// Threshold value 0.08: empirically a meaningful display jump (~8 percentile points).
// Larger would miss subtle deepenings; smaller would fire on noise.
private let kDeepeningWindow: Int     = 60     // 60 windows × 0.5s = 30s rolling
private let kDeepeningDelta: Float    = 0.08
private let kDeepeningCooldown: TimeInterval = 60.0

final class DepthGate {
    // B126: per-session sustained-window requirement. Re-read from EnterSustainedShaping at
    // every reset() so shaping changes take effect on the next session, not next app launch.
    private var kEnterSustained: Int = EnterSustainedShaping.currentWindows()

    private(set) var inDeepState   = false
    private(set) var smoothedScore: Float = 0.5      // legacy sigmoid-space; still used by some UI
    private(set) var smoothedDisplay: Float = 0.0    // B77: ECDF display, [0, 1]
    private var kalman      = KalmanDepth()
    private var duckDisplay: Float = 0.0   // B94: slower EMA for proximity duck only

    // Adaptive thresholds in ECDF space (B77+). Default 0.70 = enter when in top 30% of
    // personal history; 0.50 = exit when at or below personal median.
    // Bounds [0.50, 0.85]: lower extends sensitivity for new users; upper challenges advanced.
    var enterThresholdEcdf: Float = 0.70
    var exitThresholdEcdf:  Float = 0.50

    // Legacy sigmoid-space mirrors used by some persisted UserDefaults paths and adaptive
    // analytics. Keep synced via setEcdfThresholds() so all code reads consistent values.
    var enterThreshold: Float = 0.70
    var exitThreshold:  Float = 0.50

    private var consecutiveAbove   = 0
    private var consecutiveBelow   = 0
    private var lastEnterChime     = Date.distantPast
    private var lastExitChime      = Date.distantPast
    private var contactLossWindows = 0
    private var thresholdConfigured = false

    // Anchor state — re-fires on entering top-10% of personal ECDF (vs B76 single-fire-per-episode).
    private var deepStateEnteredAt:    Date = .distantPast
    private var lastAnchorDate:        Date = .distantPast
    private var lastAnchorAboveTop:    Bool = false  // for crossing detection

    // Deepening cue rolling-window state. Pre-allocated 60-slot ring buffer for the past
    // 30s of smoothedDisplay values; current minus oldest = 30s rate.
    private var deepeningRing      = [Float](repeating: 0, count: kDeepeningWindow)
    private var deepeningRingHead  = 0
    private var deepeningRingFilled = 0
    private var lastDeepeningCue:  Date = .distantPast

    // B94 — FAA flow state
    private var smoothedFaa:       Float = 0.0
    private let kFaaAlpha:         Float = 0.10          // tau ≈ 5s at 0.5s update rate
    private(set) var faaBaseline:  Float = -0.092        // population median; overwritten at calib end
    private var faaBaselineLocked: Bool  = false
    private let kFaaFlowMargin:    Float = 0.25          // ≈ top 25% of session FAA distribution
    private let kFaaSustained:     Int   = 10            // 5s at 0.5s update rate
    private var consecutiveFlow:   Int   = 0
    private var consecutiveFlowExit: Int = 0
    private(set) var inFlowState:  Bool  = false
    private var lastFlowChime:     Date  = .distantPast
    private let kFlowCooldown:     TimeInterval = 120.0

    // B126: alpha-theta crossover accumulator (calibrated, good-contact windows only).
    private var alphaThetaSum:             Double = 0   // Double for precision over long sessions
    private var alphaThetaCount:           Int    = 0
    private var alphaThetaCrossoverCount:  Int    = 0      // windows where theta/alpha > 1.0
    private var alphaThetaCrossoverFirstTimeSec: Double? = nil
    private var sessionStartDate:          Date   = .distantPast

    // B126 — Deep state maintenance protocol (Lane 1998; Wahbeh 2007; Pfurtscheller 1999).
    // Once in deep state, FADE soundscape rather than holding it. Internally-generated
    // theta is the signal; external soundscape is now a distraction.
    private let kDeepInitialFadeSec:    Double = 30.0   // was 2.0 (B125 default)
    private let kDeepInitialFadeTarget: Float  = 0.20   // was 0.15 (slightly louder floor)
    private let kDeepExitFadeSec:       Double = 5.0    // was 3.0 — slower exit signal
    private let kSilenceGapEverySec:    Double = 120.0  // every 2 minutes in deep
    private let kSilenceGapMinSec:      Double = 8.0
    private let kSilenceGapMaxSec:      Double = 12.0
    private let kFirstChimeBlackoutSec: Double = 60.0   // suppress playDeepening for first 60s
    private var lastSilenceGapAt:       Date   = .distantPast

    // B126 — BOCPD drift alert. Observes smoothedDisplay at 2Hz while inDeepState.
    // Fires when: posterior > 0.75 AND smoothedDisplay declined ≥0.05 over 10-sample (5s) lookback.
    // Cooldown 90s between alerts.
    private var driftDetector = BayesianChangepointDetector(hazardRate: 1.0 / 250.0)
    private var smoothedDisplayHistory: [Float] = []
    private let kDriftLookback:          Int    = 10
    private let kDriftMinDecline:        Float  = 0.05
    private var lastDriftAlert:          Date   = .distantPast
    private let kDriftAlertCooldown:     TimeInterval = 90.0
    private let kDriftPosteriorThreshold: Float = 0.75

    /// B126: fired when BOCPD detects a downward drift in deep state.
    /// Parameters: (sessionElapsedSec, posterior, ecdfAtAlert).
    var onDriftAlert: ((Double, Float, Float) -> Void)?

    private let chime = ChimeEngine.shared
    private let zDist = PersonalZDistribution.shared

    var frontalContactGood: Bool = true
    // Set externally from pipeline.onITPFUpdate before each update() call.
    var lastKnownITPF: Float? = nil

    /// B107: set adaptive Kalman process noise from calibration ECDF variance.
    /// Clamped to [0.0005, 0.020] by caller; method trusts caller but re-clamps for safety.
    func setQD(_ qD: Float) {
        kalman.qD = max(0.0005, min(0.020, qD))
    }

    /// B126: set session start time so crossoverFirstTimeSec is relative to session, not app launch.
    func setSessionStart(_ d: Date) {
        sessionStartDate = d
    }

    /// B126: drain alpha-theta summary at session end. Caller passes to SessionRecorder.attachAlphaThetaSummary.
    /// Returns nil mean when no calibrated samples accumulated (sub-60s session).
    func alphaThetaSummary() -> (mean: Float?, crossoverCount: Int, crossoverFirstTimeSec: Double?) {
        let mean: Float? = alphaThetaCount > 0 ? Float(alphaThetaSum / Double(alphaThetaCount)) : nil
        return (mean, alphaThetaCrossoverCount, alphaThetaCrossoverFirstTimeSec)
    }

    func setEcdfThresholds(enter: Float, exit: Float) {
        enterThresholdEcdf = max(0.50, min(0.85, enter))
        exitThresholdEcdf  = max(0.40, min(enterThresholdEcdf - 0.10, exit))
        enterThreshold = enterThresholdEcdf
        exitThreshold  = exitThresholdEcdf
    }

    func update(_ result: DepthResult) {
        guard result.isCalibrated else {
            smoothedScore   = 0.5
            smoothedDisplay = 0.0
            return
        }

        // Adaptive threshold: scale to personal history depth on first calibrated window.
        // Prevents gate from being unreachable for users with <5 sessions.
        if !thresholdConfigured {
            let n = zDist.sessionCount
            let (enter, exit): (Float, Float) =
                n == 0 ? (0.55, 0.40) :
                n <  5 ? (0.60, 0.45) :
                n < 20 ? (0.65, 0.48) :
                         (0.70, 0.50)
            setEcdfThresholds(enter: enter, exit: exit)
            thresholdConfigured = true
        }

        guard frontalContactGood else {
            contactLossWindows += 1
            // Bad contact = unknown state. Hold 30s (60 windows × 0.5s), then slow decay.
            // smoothedDisplay (Kalman) intentionally frozen during contact loss — last estimate
            // is more honest than artificial decay. smoothedScore decays toward 0.5 as fallback.
            if contactLossWindows > 60 {
                smoothedScore = 0.97 * smoothedScore + 0.03 * 0.5
            }
            SoundscapePlayer.shared.setProximityGain(1.0)
            return
        }
        contactLossWindows = 0

        // B126: accumulate alpha-theta ratio. Sanity-bounded: <0 or ≥50 = degenerate channel.
        let atNow = result.alphaTheta
        if atNow.isFinite && atNow > 0 && atNow < 50 {
            alphaThetaSum   += Double(atNow)
            alphaThetaCount += 1
            if atNow > 1.0 {    // crossover: theta > alpha
                alphaThetaCrossoverCount += 1
                if alphaThetaCrossoverFirstTimeSec == nil {
                    alphaThetaCrossoverFirstTimeSec = Date().timeIntervalSince(sessionStartDate)
                }
            }
        }

        // EMA on legacy sigmoid score (retained for any UI callers reading smoothedScore).
        smoothedScore = kEmaAlpha * result.score + (1 - kEmaAlpha) * smoothedScore

        // B94: Kalman filter replaces EMA for smoothedDisplay.
        // duckDisplay is a slower second-stage smoother for proximity gain only.
        let displayNow = zDist.ecdf(result.z)
        let (kalmanDepth, _) = kalman.update(z: displayNow,
                                              alphaPowerRatio: result.alphaPowerRatio)
        smoothedDisplay = kalmanDepth
        duckDisplay     = kDuckAlpha * displayNow + (1 - kDuckAlpha) * duckDisplay

        // FAA smoothing and baseline lock at calibration end
        smoothedFaa = kFaaAlpha * result.faa + (1 - kFaaAlpha) * smoothedFaa
        if result.isCalibrated && !faaBaselineLocked {
            faaBaseline       = smoothedFaa
            faaBaselineLocked = true
        }

        // B126: replaced applyProximityDuck() with continuous sonification (reverb-driven).
        // The old method is preserved for emergency rollback via Settings toggle (TBD post-B126).
        applyContinuousSonification()

        let now = Date()

        if !inDeepState {
            if smoothedDisplay >= enterThresholdEcdf {
                consecutiveAbove += 1
                consecutiveBelow  = 0
            } else {
                consecutiveAbove  = 0
            }

            if consecutiveAbove >= kEnterSustained,
               now.timeIntervalSince(lastEnterChime) >= kCooldown {
                inDeepState        = true
                consecutiveAbove   = 0
                lastEnterChime     = now
                deepStateEnteredAt = now
                lastAnchorAboveTop = false
                SoundscapePlayer.shared.setProximityGain(1.0)
                // B126: longer initial fade (30s vs 2s) lets internally-generated theta emerge.
                // Target 0.20 (slightly louder than B125's 0.15 to remain audible as an anchor).
                SoundscapePlayer.shared.setDeepStateGain(kDeepInitialFadeTarget,
                                                         fadeDuration: kDeepInitialFadeSec)
                lastSilenceGapAt = now   // arm the 2-min silence-gap clock
                chime.playEnterDeep()
            }
        } else {
            // Anchor re-fire on crossing into top-10% personal ECDF, with kAnchorCooldown
            // between any two firings. Up to ~12 anchors per hour-long session, contingent
            // on real depth excursions.
            let aboveTop = smoothedDisplay >= kAnchorEcdfThreshold
            let crossed  = aboveTop && !lastAnchorAboveTop
            if crossed,
               now.timeIntervalSince(deepStateEnteredAt) >= kAnchorDelay,
               now.timeIntervalSince(lastAnchorDate)     >= kAnchorCooldown {
                lastAnchorDate = now
                chime.playConditioningAnchor()
            }
            lastAnchorAboveTop = aboveTop

            // Deepening cue: 30s rolling window rate-of-change. Captures "going deeper"
            // even when the user is already pegged in deep — addresses B76's "no
            // increment chimes" feedback. Ring buffer: write current, compute rate from
            // oldest before write, then advance head.
            // Read before overwrite: ring[head] is the value from kDeepeningWindow steps ago
            // (the slot we're about to replace). (head+1)%N was the pre-fix read target —
            // that was the second-oldest, giving a 29.5s window instead of 30s.
            let oldestVal = deepeningRing[deepeningRingHead]
            deepeningRing[deepeningRingHead] = smoothedDisplay
            deepeningRingHead = (deepeningRingHead + 1) % kDeepeningWindow
            deepeningRingFilled = min(deepeningRingFilled + 1, kDeepeningWindow)
            if deepeningRingFilled >= kDeepeningWindow {
                let rise = smoothedDisplay - oldestVal
                if rise >= kDeepeningDelta,
                   now.timeIntervalSince(lastDeepeningCue) >= kDeepeningCooldown,
                   now.timeIntervalSince(deepStateEnteredAt) >= kFirstChimeBlackoutSec {
                    lastDeepeningCue = now
                    chime.playDeepening()
                }
            }

            // B126: silence gap every 2 minutes after first entry. Random duration
            // [kSilenceGapMinSec, kSilenceGapMaxSec] introduces noise into the
            // gap-prediction so the user does not entrain to a fixed cadence.
            if now.timeIntervalSince(lastSilenceGapAt) >= kSilenceGapEverySec {
                let dur = Double.random(in: kSilenceGapMinSec...kSilenceGapMaxSec)
                let target = kDeepInitialFadeTarget
                lastSilenceGapAt = now
                DispatchQueue.main.async {
                    SoundscapePlayer.shared.enterSilenceGap(durationSec: dur, postGapTarget: target)
                }
            }

            // B126: BOCPD drift detection. Derivative measured over 10-sample (5s) lookback
            // on smoothedDisplay (not on the posterior itself).
            let posterior = driftDetector.observe(smoothedDisplay)
            smoothedDisplayHistory.append(smoothedDisplay)
            if smoothedDisplayHistory.count > kDriftLookback {
                smoothedDisplayHistory.removeFirst()
            }
            let derivative: Float = smoothedDisplayHistory.count == kDriftLookback
                ? smoothedDisplay - smoothedDisplayHistory[0]
                : 0
            let silenceGapRecoveryEnd = lastSilenceGapAt.addingTimeInterval(kSilenceGapMaxSec + 3.5)
            if posterior > kDriftPosteriorThreshold,
               derivative < -kDriftMinDecline,
               now.timeIntervalSince(lastDriftAlert) >= kDriftAlertCooldown,
               now >= silenceGapRecoveryEnd {
                lastDriftAlert = now
                let tSec = now.timeIntervalSince(sessionStartDate)
                onDriftAlert?(tSec, posterior, smoothedDisplay)
            }

            if smoothedDisplay < exitThresholdEcdf {
                consecutiveBelow += 1
                consecutiveAbove  = 0
            } else {
                consecutiveBelow  = 0
            }

            if consecutiveBelow >= kExitSustained,
               now.timeIntervalSince(lastExitChime) >= kCooldown {
                inDeepState      = false
                consecutiveBelow = 0
                lastExitChime    = now
                // B126: slower exit fade (5s vs 3s) — less abrupt re-entry of soundscape.
                SoundscapePlayer.shared.setDeepStateGain(1.0, fadeDuration: kDeepExitFadeSec)
                chime.playExitDeep()
                inFlowState         = false
                consecutiveFlow     = 0
                consecutiveFlowExit = 0
            }

            // B94 — FAA flow state: deep + positive frontal asymmetry sustained 5s
            let flowSignal = smoothedFaa > faaBaseline + kFaaFlowMargin
            consecutiveFlow = flowSignal ? consecutiveFlow + 1 : 0
            if consecutiveFlow >= kFaaSustained,
               !inFlowState,
               now.timeIntervalSince(lastFlowChime) >= kFlowCooldown {
                inFlowState   = true
                lastFlowChime = now
                chime.playFlow()
            }
            // Exit flow only after 3 consecutive samples below threshold (1.5s hysteresis).
            // Single-sample exit would collapse genuine flow state on momentary FAA noise.
            if smoothedFaa < faaBaseline + kFaaFlowMargin * 0.3 {
                consecutiveFlowExit += 1
                if consecutiveFlowExit >= 3 {
                    inFlowState         = false
                    consecutiveFlow     = 0
                    consecutiveFlowExit = 0
                }
            } else {
                consecutiveFlowExit = 0
            }
        }
    }

    // Silently reduce soundscape as duckDisplay approaches enterThresholdEcdf.
    // Called after every EMA update. Must be called on main thread (same as update()).
    // Gain 1.0 at display ≤ 0.30, 0.15 at display ≥ enterThresholdEcdf.
    // While inDeepState: deepStateGain owns the level — don't touch proximityGain.
    private func applyProximityDuck() {
        guard !inDeepState else { return }
        let lo: Float = 0.30
        let hi = enterThresholdEcdf
        guard duckDisplay > lo else {
            SoundscapePlayer.shared.setProximityGain(1.0)
            return
        }
        let t = min(1.0, (duckDisplay - lo) / (hi - lo))
        SoundscapePlayer.shared.setProximityGain(1.0 - t * 0.85)
    }

    /// B126: continuous ECDF-to-audio mapping (replaces applyProximityDuck step function).
    /// Maps smoothedDisplay to reverb presence linearly between lo and enterThresholdEcdf.
    /// Below lo: no reverb. At threshold: full reverb (presence = 1). Guard: !inDeepState.
    private func applyContinuousSonification() {
        guard !inDeepState else { return }
        let lo: Float = 0.30
        let hi = enterThresholdEcdf
        let presence: Float
        if smoothedDisplay <= lo {
            presence = 0
        } else if smoothedDisplay >= hi {
            presence = 1
        } else {
            presence = (smoothedDisplay - lo) / (hi - lo)
        }
        DispatchQueue.main.async {
            SoundscapePlayer.shared.setAmbientPresence(presence)
        }
    }

    func reset() {
        // B126: re-read shaping value so the next session reflects the updated UserDefault.
        kEnterSustained    = EnterSustainedShaping.currentWindows()
        inDeepState        = false
        smoothedScore      = 0.5
        smoothedDisplay    = 0.0
        kalman.reset()
        kalman.qD          = 0.0022   // B107: restore default; next session re-adapts at calibration end
        duckDisplay        = 0.0
        SoundscapePlayer.shared.setProximityGain(1.0)
        SoundscapePlayer.shared.resetDeepStateGain()
        consecutiveAbove   = 0
        consecutiveBelow   = 0
        lastEnterChime     = .distantPast
        lastExitChime      = .distantPast
        deepStateEnteredAt = .distantPast
        lastAnchorDate     = .distantPast
        lastSilenceGapAt   = .distantPast
        lastAnchorAboveTop = false
        contactLossWindows = 0
        thresholdConfigured = false
        deepeningRing      = [Float](repeating: 0, count: kDeepeningWindow)
        deepeningRingHead  = 0
        deepeningRingFilled = 0
        lastDeepeningCue   = .distantPast
        lastKnownITPF      = nil
        smoothedFaa       = 0.0
        faaBaselineLocked = false
        faaBaseline       = -0.092
        consecutiveFlow     = 0
        consecutiveFlowExit = 0
        inFlowState         = false
        lastFlowChime     = .distantPast
        alphaThetaSum              = 0.0
        alphaThetaCount            = 0
        alphaThetaCrossoverCount   = 0
        alphaThetaCrossoverFirstTimeSec = nil
        sessionStartDate           = .distantPast
        driftDetector          = BayesianChangepointDetector(hazardRate: 1.0 / 250.0)
        smoothedDisplayHistory = []
        lastDriftAlert         = .distantPast
        // Thresholds reconfigured adaptively on next calibrated update.
    }
}
