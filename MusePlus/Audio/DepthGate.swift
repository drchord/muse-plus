import Foundation

// MARK: - Tuning constants

// Hysteresis: enter high, exit lower — prevents oscillation at boundary
private let kEnterThreshold: Float    = 0.65
private let kExitThreshold:  Float    = 0.50

// Score must hold above/below threshold for this many 0.5s windows before chiming.
// Enter: 10s — responsive enough to reward genuine depth without false positives.
// Exit: 10s — matches enter for symmetry; reduces ping-pong at threshold.
private let kEnterSustained: Int      = 20   // 20 × 0.5 s = 10 s
private let kExitSustained:  Int      = 20   // 20 × 0.5 s = 10 s

// Minimum gap between two chimes in the same direction.
// 90s cooldown: allows multiple training cycles per 20-min session.
private let kCooldown: TimeInterval   = 90   // 1.5 minutes

// EMA alpha = 0.20 → time constant ~4 windows (~2s) — fast enough to track real shifts.
private let kEmaAlpha: Float          = 0.20

final class DepthGate {
    private(set) var inDeepState   = false
    private(set) var smoothedScore: Float = 0.5

    private var consecutiveAbove   = 0
    private var consecutiveBelow   = 0
    private var lastEnterChime     = Date.distantPast
    private var lastExitChime      = Date.distantPast

    private let chime = ChimeEngine.shared

    var contactsGood: Bool = true   // set by Probe on every fit-check update

    // Call every time a new DepthResult arrives.
    func update(_ result: DepthResult) {
        guard result.isCalibrated, contactsGood else {
            smoothedScore = 0.5
            return
        }

        // Exponential moving average — smooths out per-window jitter
        smoothedScore = kEmaAlpha * result.score + (1 - kEmaAlpha) * smoothedScore

        let now = Date()

        if !inDeepState {
            if smoothedScore >= kEnterThreshold {
                consecutiveAbove += 1
                consecutiveBelow  = 0
            } else {
                consecutiveAbove  = 0
            }

            if consecutiveAbove >= kEnterSustained,
               now.timeIntervalSince(lastEnterChime) >= kCooldown {
                inDeepState      = true
                consecutiveAbove = 0
                lastEnterChime   = now
                chime.playEnterDeep()
            }

        } else {
            if smoothedScore < kExitThreshold {
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
        inDeepState      = false
        smoothedScore    = 0.5
        consecutiveAbove = 0
        consecutiveBelow = 0
        lastEnterChime   = .distantPast
        lastExitChime    = .distantPast
    }
}
