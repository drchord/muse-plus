import Foundation
import CoreHaptics
import UserNotifications
import AVFoundation

// MARK: - PauseReason

enum PauseReason: String {
    case bleDrop          = "BLE disconnect"
    case audioInterruption = "Audio interruption"
    case contactLost      = "Contact lost"
    case lowBattery       = "Low battery"
    case suspended        = "App suspended"
}

// MARK: - AlertCoordinator
//
// Single entry point for all user-alerting during a meditation session.
// Three channels fire simultaneously on every event:
//   1. CoreHaptics — distinct pattern per event (4 patterns, no repeats between events)
//   2. ChimeEngine — audio chimes sized for in-session use (non-jarring)
//   3. UNUserNotificationCenter — .timeSensitive bypasses Focus modes (iOS 15+)
//
// Call requestAuthorization() once at launch (from Probe.start()).
// All methods are safe to call from the main thread.

final class AlertCoordinator {
    static let shared = AlertCoordinator()

    // MARK: - CoreHaptics

    private var hapticEngine: CHHapticEngine?
    private var hapticSupported: Bool = false

    private func initHapticEngineIfNeeded() {
        guard hapticSupported, hapticEngine == nil else { return }
        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.stoppedHandler = { [weak self] reason in
                Telemetry.audio.error("haptic engine stopped reason=\(reason.rawValue, privacy: .public)")
                self?.hapticEngine = nil
            }
            hapticEngine?.resetHandler = { [weak self] in
                do {
                    try self?.hapticEngine?.start()
                } catch {
                    Telemetry.audio.error("haptic engine reset failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            try hapticEngine?.start()
        } catch {
            Telemetry.audio.error("haptic engine init failed: \(error.localizedDescription, privacy: .public)")
            hapticEngine = nil
        }
    }

    // MARK: - Init

    private init() {
        hapticSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - Authorization

    /// Call once at launch. Requests notification permission.
    func requestAuthorization() async {
        do {
            let center = UNUserNotificationCenter.current()
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
            Telemetry.connection.notice("notification authorization granted")
        } catch {
            Telemetry.connection.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Public API

    /// Session paused — BLE drop, audio interruption, etc.
    /// Pattern: 3 sharp ascending transients (urgent but not alarming).
    func sessionPaused(reason: PauseReason) {
        Telemetry.audio.error("sessionPaused reason=\(reason.rawValue, privacy: .public)")
        playHapticPause()
        ChimeEngine.shared.playPauseChime()
        postNotification(
            title: "Session Paused",
            body: reason == .bleDrop
                ? "Muse headband disconnected. Reconnecting — keep headband on."
                : "Session paused: \(reason.rawValue). Will resume automatically.",
            identifier: "session-paused"
        )
    }

    /// Session resumed after a grace-period reconnect.
    /// Pattern: 1 long continuous rising tone (relief, resumption).
    func sessionResumed() {
        Telemetry.audio.notice("sessionResumed")
        playHapticResume()
        ChimeEngine.shared.playResumeChime()
        postNotification(
            title: "Session Resumed",
            body: "Headband reconnected. Your session continues.",
            identifier: "session-resumed"
        )
    }

    /// Session ended cleanly (user tap or timer).
    /// Pattern: 3 long descending transients (completion, calm).
    func sessionEndedSuccess(durationMin: Double) {
        Telemetry.recording.notice("sessionEndedSuccess durationMin=\(durationMin, privacy: .public)")
        playHapticEndSuccess()
        ChimeEngine.shared.playSuccessChime()
        let mins = Int(durationMin)
        postNotification(
            title: "Session Complete",
            body: "Great sit — \(mins) min recorded.",
            identifier: "session-end-success"
        )
    }

    /// Session ended due to failure (grace timeout, unrecoverable error).
    /// Pattern: 5 sharp rapid transients (attention, something went wrong).
    func sessionEndedFailure(reason: String) {
        Telemetry.recording.error("sessionEndedFailure reason=\(reason, privacy: .public)")
        playHapticEndFailure()
        ChimeEngine.shared.playFailureChime()
        postNotification(
            title: "Session Ended",
            body: "Session saved early: \(reason).",
            identifier: "session-end-failure"
        )
    }

    // MARK: - Haptic patterns

    // Pause: 3 sharp ascending transients (100ms gap between each)
    private func playHapticPause() {
        guard hapticSupported else { return }
        initHapticEngineIfNeeded()
        guard let engine = hapticEngine else { return }
        let intensities: [Float] = [0.4, 0.65, 0.9]
        let sharpnesses: [Float] = [0.8, 0.85, 0.9]
        var events: [CHHapticEvent] = []
        for (i, (intensity, sharpness)) in zip(intensities, sharpnesses).enumerated() {
            let t = Double(i) * 0.12
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: t
            ))
        }
        playHaptic(events: events, engine: engine)
    }

    // Resume: 1 long continuous rising pattern (0.6s)
    private func playHapticResume() {
        guard hapticSupported else { return }
        initHapticEngineIfNeeded()
        guard let engine = hapticEngine else { return }
        let events = [
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                ],
                relativeTime: 0,
                duration: 0.6
            )
        ]
        playHaptic(events: events, engine: engine)
    }

    // End success: 3 long descending transients (200ms gap)
    private func playHapticEndSuccess() {
        guard hapticSupported else { return }
        initHapticEngineIfNeeded()
        guard let engine = hapticEngine else { return }
        let intensities: [Float] = [0.9, 0.65, 0.4]
        let sharpnesses: [Float] = [0.3, 0.25, 0.2]
        var events: [CHHapticEvent] = []
        for (i, (intensity, sharpness)) in zip(intensities, sharpnesses).enumerated() {
            let t = Double(i) * 0.22
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: t
            ))
        }
        playHaptic(events: events, engine: engine)
    }

    // End failure: 5 sharp rapid transients (60ms gap)
    private func playHapticEndFailure() {
        guard hapticSupported else { return }
        initHapticEngineIfNeeded()
        guard let engine = hapticEngine else { return }
        var events: [CHHapticEvent] = []
        for i in 0..<5 {
            let t = Double(i) * 0.07
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.85),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.95),
                ],
                relativeTime: t
            ))
        }
        playHaptic(events: events, engine: engine)
    }

    private func playHaptic(events: [CHHapticEvent], engine: CHHapticEngine) {
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player  = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            Telemetry.audio.error("haptic playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notifications

    private func postNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = UNNotificationSound.default
        // .timeSensitive bypasses Focus modes (iOS 15+) — critical for eyes-closed sessions
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        // Fire immediately (timeInterval must be > 0)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Telemetry.audio.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
