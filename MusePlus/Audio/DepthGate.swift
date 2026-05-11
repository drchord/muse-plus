import Foundation

// MARK: - Tuning constants (file-level, never change per-instance)

// Score must hold above/below threshold for this many 0.5s windows before chiming.
private let kEnterSustained: Int    = 20   // 20 × 0.5 s = 10 s
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
    private var faaBaseline:       Float = -0.092        // population median; overwritten at calib end
    private var faaBaselineLocked: Bool  = false
    private let kFaaFlowMargin:    Float = 0.25          // ≈ top 25% of session FAA distribution
    private let kFaaSustained:     Int   = 10            // 5s at 0.5s update rate
    private var consecutiveFlow:   Int   = 0
    private var consecutiveFlowExit: Int = 0
    private(set) var inFlowState:  Bool  = false
    private var lastFlowChime:     Date  = .distantPast
    private let kFlowCooldown:     TimeInterval = 120.0

    private let chime = ChimeEngine.shared
    private let zDist = PersonalZDistribution.shared

    var frontalContactGood: Bool = true
    // Set externally from pipeline.onITPFUpdate before each update() call.
    var lastKnownITPF: Float? = nil

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

        applyProximityDuck()

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
            let oldestIdx = (deepeningRingHead + 1) % kDeepeningWindow
            let oldestVal = deepeningRing[oldestIdx]
            deepeningRing[deepeningRingHead] = smoothedDisplay
            deepeningRingHead = oldestIdx
            deepeningRingFilled = min(deepeningRingFilled + 1, kDeepeningWindow)
            if deepeningRingFilled >= kDeepeningWindow {
                let rise = smoothedDisplay - oldestVal
                if rise >= kDeepeningDelta,
                   now.timeIntervalSince(lastDeepeningCue) >= kDeepeningCooldown {
                    lastDeepeningCue = now
                    chime.playDeepening()
                }
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
    // While inDeepState: restores full gain (chime duck system takes over).
    private func applyProximityDuck() {
        guard !inDeepState else {
            SoundscapePlayer.shared.setProximityGain(1.0)
            return
        }
        let lo: Float = 0.30
        let hi = enterThresholdEcdf
        guard duckDisplay > lo else {
            SoundscapePlayer.shared.setProximityGain(1.0)
            return
        }
        let t = min(1.0, (duckDisplay - lo) / (hi - lo))
        SoundscapePlayer.shared.setProximityGain(1.0 - t * 0.85)
    }

    func reset() {
        inDeepState        = false
        smoothedScore      = 0.5
        smoothedDisplay    = 0.0
        kalman.reset()
        duckDisplay        = 0.0
        SoundscapePlayer.shared.setProximityGain(1.0)
        consecutiveAbove   = 0
        consecutiveBelow   = 0
        lastEnterChime     = .distantPast
        lastExitChime      = .distantPast
        deepStateEnteredAt = .distantPast
        lastAnchorDate     = .distantPast
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
        // Thresholds reconfigured adaptively on next calibrated update.
    }
}
