import Foundation

// MARK: - Tuning constants (file-level, never change per-instance)

// Score must hold above/below threshold for this many 0.5s windows before chiming.
private let kEnterSustained: Int    = 20   // 20 × 0.5 s = 10 s
private let kExitSustained:  Int    = 20
// Minimum gap between two enter/exit chimes (same direction).
private let kCooldown: TimeInterval = 90   // 1.5 minutes
// EMA alpha = 0.20 → time constant ~4 windows (~2s)
private let kEmaAlpha: Float        = 0.20
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

final class DepthGate {
    private(set) var inDeepState   = false
    private(set) var smoothedScore: Float = 0.5

    // Adaptive thresholds: default population values; overwritten by Probe after 5+ sessions.
    var enterThreshold: Float = 0.65
    var exitThreshold:  Float = 0.50

    private var consecutiveAbove   = 0
    private var consecutiveBelow   = 0
    private var lastEnterChime     = Date.distantPast
    private var lastExitChime      = Date.distantPast
    // Windows elapsed since contact was lost. Used for hold-then-decay logic.
    private var contactLossWindows = 0

    // Conditioning anchor state — separate from chime timing.
    private var deepStateEnteredAt:       Date = .distantPast
    private var conditioningAnchorFired          = false
    private var lastAnchorDate:           Date = .distantPast

    private let chime = ChimeEngine.shared

    var contactsGood: Bool = true   // set by Probe on every fit-check update

    // Call every time a new DepthResult arrives.
    func update(_ result: DepthResult) {
        guard result.isCalibrated else {
            smoothedScore = 0.5
            return
        }

        guard contactsGood else {
            contactLossWindows += 1
            // Bad contact = unknown state, not declining state.
            // Hold last known score for 30s (60 windows × 0.5s), then decay slowly.
            // Prevents gauge snapping to 50 on every TP9/TP10 fluctuation while
            // still converging to neutral if contact is genuinely lost long-term.
            if contactLossWindows > 60 {
                smoothedScore = 0.97 * smoothedScore + 0.03 * 0.5
            }
            return
        }
        contactLossWindows = 0

        smoothedScore = kEmaAlpha * result.score + (1 - kEmaAlpha) * smoothedScore

        let now = Date()

        if !inDeepState {
            if smoothedScore >= enterThreshold {
                consecutiveAbove += 1
                consecutiveBelow  = 0
            } else {
                consecutiveAbove  = 0
            }

            if consecutiveAbove >= kEnterSustained,
               now.timeIntervalSince(lastEnterChime) >= kCooldown {
                inDeepState           = true
                consecutiveAbove      = 0
                lastEnterChime        = now
                deepStateEnteredAt    = now
                conditioningAnchorFired = false
                chime.playEnterDeep()
            }

        } else {
            // Conditioning anchor: fires kAnchorDelay after entering deep, once per episode,
            // with kAnchorCooldown between any two anchors. Plays a 7 Hz binaural theta tone
            // that acts as a Pavlovian state anchor — the brain learns to associate the sound
            // with this exact state, speeding induction in future sessions.
            if !conditioningAnchorFired,
               now.timeIntervalSince(deepStateEnteredAt) >= kAnchorDelay,
               now.timeIntervalSince(lastAnchorDate) >= kAnchorCooldown {
                conditioningAnchorFired = true
                lastAnchorDate          = now
                chime.playConditioningAnchor()
            }

            if smoothedScore < exitThreshold {
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
            }
        }
    }

    func reset() {
        inDeepState             = false
        smoothedScore           = 0.5
        consecutiveAbove        = 0
        consecutiveBelow        = 0
        lastEnterChime          = .distantPast
        lastExitChime           = .distantPast
        deepStateEnteredAt      = .distantPast
        conditioningAnchorFired = false
        lastAnchorDate          = .distantPast
        contactLossWindows      = 0
        // Intentionally NOT resetting enterThreshold / exitThreshold — persists across sessions.
    }
}
