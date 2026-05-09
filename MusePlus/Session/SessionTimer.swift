import Foundation
import Combine
import os.log

// MARK: - SessionTimer
//
// Auto-starts when calibration completes (hooked in Probe.scorer.onResult).
// Counts down selectedDurationMin × 60 seconds, then calls onExpire.
// Distinct from MeditationTimer (the user-visible manual countdown in Settings).
//
// Cross-agent note: endSessionGracefully(reason:) checks isPausedForReconnect
// (Agent B's flag) before calling manualEndSession(). If Agent B adds that
// property to Probe, the guard will activate automatically.

final class SessionTimer: ObservableObject {
    static let shared = SessionTimer()
    // B83: expanded presets — user reported B82 session was 20 min but no preset matched, forcing manual end.
    static let allowedDurations = [5, 10, 15, 20, 25, 30, 45, 60, 75, 90, 120]  // minutes

    @Published private(set) var remainingSec: Int = 0
    @Published private(set) var isRunning: Bool = false

    @Published var selectedDurationMin: Int {
        didSet {
            UserDefaults.standard.set(selectedDurationMin, forKey: "sessionDurationMin")
        }
    }

    /// Called on main thread when timer expires.
    var onExpire: (() -> Void)?

    var formattedRemaining: String {
        let r = max(0, remainingSec)
        let h = r / 3600
        let m = (r % 3600) / 60
        let s = r % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private var timer: Timer?

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "sessionDurationMin")
        self.selectedDurationMin = Self.allowedDurations.contains(saved) ? saved : 75
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        remainingSec = selectedDurationMin * 60
        isRunning    = true
        Telemetry.recording.notice("SessionTimer start duration=\(self.selectedDurationMin, privacy: .public)min")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Keep timer firing when screen is off / RunLoop is in common mode
        RunLoop.main.add(timer!, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer        = nil
        isRunning    = false
        remainingSec = 0
        Telemetry.recording.notice("SessionTimer cancelled")
    }

    // MARK: - Private

    private func tick() {
        guard remainingSec > 0 else { return }
        remainingSec -= 1
        if remainingSec == 0 {
            timer?.invalidate()
            timer     = nil
            isRunning = false
            Telemetry.recording.notice("SessionTimer expired at \(self.selectedDurationMin, privacy: .public)min")
            DispatchQueue.main.async { [weak self] in
                self?.onExpire?()
            }
        }
    }
}
