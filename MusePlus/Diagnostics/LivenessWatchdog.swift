import Foundation
import OSLog

// MARK: - LivenessWatchdog
//
// EWMA-based EEG packet stall detector. Computes online mean inter-arrival time (tau)
// and standard deviation (sigma) from a Welford-like exponential moving average.
// A 5Hz check timer fires a stall callback when elapsed > tau + 5*sigma AND elapsed > 3.0s.
//
// Wiring (Probe.start()):
//   LivenessWatchdog.shared.onStallDetected = { gap in … }
//   client.eegPacket sink: LivenessWatchdog.shared.packetReceived()
//   .connected:  LivenessWatchdog.shared.start()
//   .disconnected: LivenessWatchdog.shared.stop()
//
// Thread-safety: all mutable state accessed only on internal serial queue.
// onStallDetected fires on internal queue — callers must dispatch to main if needed.
//
// Algorithm notes (for the math-curious):
//   Muse delivers EEG at 256 Hz (Athena) or ~220 Hz (legacy), but eegPacket is
//   dispatched to main at raw rate before the FFT window accumulates — effectively
//   arriving at the pipeline at ~2 Hz (one BandPowers sample per 0.5s window).
//   However LivenessWatchdog is wired BEFORE the pipeline (raw eegPacket subject),
//   so it sees ~220-256 packets/s with tau ≈ 4ms, sigma ≈ 1ms.
//   The 5σ threshold ≈ 4+5 = ~9ms is far too tight for a 5Hz timer check.
//   The absolute floor (3.0s) dominates in normal operation: stall fires only when
//   no packet arrives for >3s, regardless of the EWMA state. The EWMA + 5σ term
//   becomes the operative gate if delivery degrades to ~1-2 Hz (BLE congestion).
//   At 1 Hz, tau ≈ 1.0s, sigma ≈ 0.3s → threshold ≈ 2.5s < 3.0s floor, so the
//   floor still dominates. At 0.1 Hz, tau ≈ 10s, sigma ≈ 3s → threshold ≈ 25s;
//   the EWMA term takes over, giving an adaptive "missing two expected beats" gate.
//   This is intentional: a slow drip at 0.1 Hz is not a stall.
//   If the Muse SDK ever delivers data at true ~1-2 Hz in degraded-BLE mode, the
//   floor can be lowered to 2.0s without false positives at normal 256 Hz delivery.

final class LivenessWatchdog {

    static let shared = LivenessWatchdog()

    // Fired on internal queue. Callers must hop to main if needed.
    var onStallDetected: ((TimeInterval) -> Void)?

    // MARK: - Configuration

    /// EWMA smoothing factor — lower = slower adaptation.
    private let alpha: Double = 0.1
    /// Warmup packet count before stall detection activates.
    private let warmupCount: Int = 10
    /// Check timer frequency (Hz).
    private let checkHz: Double = 5.0
    /// Stall threshold multiplier on sigma.
    private let sigmaMultiplier: Double = 5.0
    /// Absolute floor below which stall never fires regardless of EWMA (seconds).
    private let absoluteFloor: Double = 3.0
    /// Minimum gap between successive stall events (seconds).
    private let stallSuppressInterval: Double = 30.0

    // MARK: - State (accessed only on queue)

    private let queue = DispatchQueue(label: "com.drchord.museplus.liveness", qos: .utility)
    private var lastTimestamp: Date?
    private var ewmaTau:    Double = 0   // mean inter-arrival (s)
    private var ewmaSigma:  Double = 0   // std of inter-arrival (s)
    private var packetCount: Int   = 0
    private var lastStallFiredAt: Date?
    private var checkTimer: DispatchSourceTimer?

    private init() {}

    // MARK: - Public API

    /// Call on every raw EEG packet (wired to client.eegPacket sink).
    func packetReceived() {
        queue.async { [self] in
            let now = Date()
            if let last = lastTimestamp {
                let gap = now.timeIntervalSince(last)
                if packetCount >= warmupCount {
                    // Welford-like EWMA variance update.
                    let oldTau = ewmaTau
                    ewmaTau   = (1 - alpha) * ewmaTau   + alpha * gap
                    let delta  = gap - oldTau
                    ewmaSigma  = sqrt(max(0, (1 - alpha) * ewmaSigma * ewmaSigma + alpha * delta * delta))
                }
            }
            lastTimestamp = now
            packetCount += 1
        }
    }

    /// Start (or restart) the watchdog. Call on .connected.
    func start() {
        queue.async { [self] in
            invalidateTimer()
            lastTimestamp    = nil
            ewmaTau          = 0
            ewmaSigma        = 0
            packetCount      = 0
            lastStallFiredAt = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1.0 / checkHz,
                           repeating: 1.0 / checkHz,
                           leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.checkForStall() }
            timer.resume()
            checkTimer = timer
            Telemetry.eeg.notice("LivenessWatchdog started")
        }
    }

    /// Stop the watchdog. Call on .disconnected.
    func stop() {
        queue.async { [self] in
            invalidateTimer()
            Telemetry.eeg.notice("LivenessWatchdog stopped")
        }
    }

    /// Snapshot of current EWMA stats. Safe to call from any thread.
    func currentStats() -> (mean: Double, std: Double, lastGap: Double, packetCount: Int) {
        queue.sync {
            let gap: Double
            if let last = lastTimestamp {
                gap = Date().timeIntervalSince(last)
            } else {
                gap = 0
            }
            return (ewmaTau, ewmaSigma, gap, packetCount)
        }
    }

    // MARK: - Private

    private func checkForStall() {
        // Must be called on queue.
        guard packetCount >= warmupCount, let last = lastTimestamp else { return }
        let elapsed = Date().timeIntervalSince(last)

        // Adaptive threshold: EWMA mean + 5σ, floored at absoluteFloor.
        let adaptiveThreshold = ewmaTau + sigmaMultiplier * ewmaSigma
        let threshold = max(absoluteFloor, adaptiveThreshold)

        guard elapsed > threshold else { return }

        // Suppress repeat fires within 30s.
        if let fired = lastStallFiredAt, Date().timeIntervalSince(fired) < stallSuppressInterval {
            return
        }
        lastStallFiredAt = Date()

        Telemetry.eeg.error("EEG liveness stall: gap=\(String(format: "%.2f", elapsed), privacy: .public)s tau=\(String(format: "%.4f", ewmaTau), privacy: .public)s sigma=\(String(format: "%.4f", ewmaSigma), privacy: .public)s threshold=\(String(format: "%.2f", threshold), privacy: .public)s packets=\(packetCount, privacy: .public)")

        onStallDetected?(elapsed)
    }

    private func invalidateTimer() {
        checkTimer?.cancel()
        checkTimer = nil
    }
}
