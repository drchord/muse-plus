// MainThreadStall.swift
// MusePlus
//
// Detects main-thread stalls during EEG recording sessions by comparing
// successive Timer tick timestamps.
//
// Threshold rationale:
//   60 Hz frame budget = 16.7 ms.
//   90 dropped frames = visibly stuck UI (~1.5 s).
//   1.5 s chosen as objective "frozen" boundary per spec.
//
// Timer on RunLoop.main in .common mode is preferred over CADisplayLink
// because we want to catch stalls even during non-rendering periods
// (e.g., pure computation or I/O hold on the main thread).
//
// iOS 16+, Swift 5.9.

import Foundation
import QuartzCore   // CACurrentMediaTime, thermalState reads
import UIKit        // UIApplication.shared.applicationState

// MARK: - MainThreadStall

final class MainThreadStall {

    // MARK: Singleton

    static let shared = MainThreadStall()

    // MARK: Public state (main-thread only)

    /// Number of stalls observed since the last `start()`.
    private(set) var stallCount: Int = 0

    // MARK: Private state

    private var timer: Timer?
    private var lastTickTime: CFTimeInterval = 0
    private var isRunning: Bool = false

    // MARK: Threshold

    private static let stallThreshold: CFTimeInterval = 1.5

    // MARK: Init

    private init() {}

    // MARK: Public API

    /// Start monitoring. Idempotent — calling while already running is a no-op.
    func start() {
        // All mutable state on main thread; assert in debug builds.
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isRunning else { return }

        stallCount = 0
        lastTickTime = CACurrentMediaTime()
        isRunning = true

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common mode: timer fires during scrolling, gesture tracking, etc.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop monitoring. Safe to call when not running.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))

        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    // MARK: Private — tick handler (always on main thread; Timer is added to RunLoop.main).
    // No @MainActor annotation — under Swift 5.9 strict concurrency, Timer block is not
    // an actor-isolated context, so the annotation would force every call site through
    // the actor and emit "non-isolated context" diagnostics. The Timer guarantee that
    // the block runs on RunLoop.main is sufficient.

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = now - lastTickTime
        lastTickTime = now

        // Ignore the very first tick (delta = time since start(), not a stall).
        guard delta > 0 else { return }

        if delta > MainThreadStall.stallThreshold {
            stallCount += 1
            reportStall(delta: delta)
        }
    }

    // MARK: Private — stall reporter

    private func reportStall(delta: CFTimeInterval) {
        // Capture context at the tick *after* recovery — best available
        // without private API. Symbols remain mangled; that is intentional.
        let top5stack = Thread.callStackSymbols
            .prefix(5)
            .joined(separator: " | ")

        let thermal = thermalStateLabel(ProcessInfo.processInfo.thermalState)

        let appState: String
        switch UIApplication.shared.applicationState {
        case .active:       appState = "active"
        case .inactive:     appState = "inactive"
        case .background:   appState = "background"
        @unknown default:   appState = "unknown"
        }

        // B83 — emit via the typed `appendMainStall` helper which writes a
        // dedicated `_type: "mainStall"` NDJSON line. Keeps stall records
        // structured for offline analysis (no string parsing required).
        SessionRecorder.shared.appendMainStall(
            deltaSec: delta,
            thermalState: thermal,
            appState: appState,
            topStack: top5stack
        )

        NSLog("[MainThreadStall] stall #%d delta=%.2fs thermal=%@ appState=%@",
              stallCount, delta, thermal, appState)
    }

    // MARK: Helpers

    private func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
