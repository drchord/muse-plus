import Foundation

// Hysteresis thresholds — enter high, exit low to prevent rapid oscillation
private let kEnterThreshold: Float = 0.65
private let kExitThreshold:  Float = 0.58
private let kDebounce: TimeInterval = 8   // minimum seconds between same-direction chimes

final class DepthGate {
    private(set) var inDeepState = false
    private var lastEnterChime = Date.distantPast
    private var lastExitChime  = Date.distantPast

    private let chime = ChimeEngine()

    // Call this every time a new DepthResult arrives (after calibration only)
    func update(_ result: DepthResult) {
        guard result.isCalibrated else { return }
        let score = result.score
        let now   = Date()

        if !inDeepState && score >= kEnterThreshold {
            guard now.timeIntervalSince(lastEnterChime) >= kDebounce else { return }
            inDeepState    = true
            lastEnterChime = now
            chime.playEnterDeep()

        } else if inDeepState && score < kExitThreshold {
            guard now.timeIntervalSince(lastExitChime) >= kDebounce else { return }
            inDeepState   = false
            lastExitChime = now
            chime.playExitDeep()
        }
    }

    func reset() {
        inDeepState    = false
        lastEnterChime = .distantPast
        lastExitChime  = .distantPast
    }
}
