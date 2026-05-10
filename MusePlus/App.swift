import SwiftUI
import Combine
import UIKit
import AVFoundation
import OSLog
import BackgroundTasks

@main
struct MusePlusApp: App {
    @StateObject private var probe = Probe()

    init() {
        // B80: register BGProcessingTask handler for crash-safe NDJSON flush.
        // Must be called before app finishes launching (before first scene connect).
        SessionRecorder.registerBackgroundTasks()
        // B83 — generate fallback bowl WAVs on first launch (idempotent).
        // Bundle .m4a / .wav take priority via EndGongPlayer.bundleURL ordering.
        BowlAudioGenerator.shared.generateIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ProbeView(probe: probe)
                .onAppear { probe.start() }
                .onOpenURL { SpotifyManager.shared.handleCallback($0) }
        }
    }
}

// MARK: - Probe

final class Probe: ObservableObject {
    // Gate 1
    @Published var muses: [String] = []
    @Published var connection: String = "—"
    @Published var fit: FitCheckSnapshot = .zero
    @Published var lastEEG: [Float] = []
    @Published var battery: Double = 0
    @Published var packetCount: Int = 0
    @Published var hsiCount: Int = 0
    @Published var hsiRaw: [Double] = []

    // Gate 2
    @Published var frontAlpha: Float = 0
    @Published var frontTheta: Float = 0
    @Published var frontBeta:  Float = 0
    @Published var frontDelta: Float = 0
    @Published var frontGamma: Float = 0
    @Published var depth: DepthResult = DepthResult(score: 0.5, z: 0, meditationIndex: 0,
                                                     meditationIndexCorrected: 0,
                                                     isCalibrated: false,
                                                     calibrationProgress: 0, faa: 0)
    // B77: subjective tap-to-mark collector. Cleared on session start.
    @Published var marks = MarkCollector()
    // B77: SDK Elements tracker for cross-validation against our pipeline.
    @ObservedObject var elements = ElementsTracker.shared
    @Published var bandUpdateCount: Int = 0
    @Published var bandHistory: [BandSample] = []
    @Published var heartRate: Double = 0
    @Published var aperiodicSlope: Float? = nil  // IRASA mean χ; nil when R² quality gate fails
    @Published var iTPFFrontal: Float?    = nil  // frontal theta peak Hz; nil until reliable

    let client   = MuseClient()
    let pipeline = EEGPipeline()
    let hrv      = HRVPipeline()
    let scorer   = DepthScore()
    let gate     = DepthGate()
    @Published var rmssd:     Float? = nil  // RMSSD in ms; nil until 5-min Optics window accumulates
    @Published var lfhfRatio: Float? = nil  // LF/HF ratio; nil until RMSSD available
    private var bag = Set<AnyCancellable>()
    private var sampleIndex = 0

    // MARK: - B80 Diagnostic state
    // All counters reset in .connected handler. Accumulated throughout session lifecycle.
    // Agent B wires disconnect/reconnect increments; Agent D wires timer-expired event.
    // This class owns the struct definition and the buildDiagnostics() helper.

    private struct SessionDiagCounters {
        var disconnectCount      = 0
        var reconnectAttempts    = 0
        var audioInterruptions   = 0
        var routeChanges         = 0
        var contactStateChanges: [String: Int] = [:]
        var stallEvents:         [StallEvent]  = []
    }
    private var sessionDiagCounters = SessionDiagCounters()
    // B83 — `sessionEvents` is dual-written with `SessionRecorder.appendEvent` (NDJSON).
    // NDJSON is the crash-survivable source of truth (recoverable via CrashRecovery).
    // The in-memory list is kept ONLY so the canonical .json synthesis path can attach
    // it via `attachEventStream` for offline analysis scripts that don't parse NDJSON.
    // If you remove this, also remove `attachEventStream` calls AND update existing
    // analysis scripts to read NDJSON `_type:"event"` lines instead of `eventStream`.
    private var sessionEvents: [SessionEvent] = []
    // B83 — count of `addFitEvent` calls this session (parallel to `_type:"fit"` NDJSON
    // line count). Used by buildDiagnostics for the contact-quality grade metric.
    private var fitEventCount: Int = 0
    // Last known HSI per-channel raw value; used to detect transitions in fitCheck sink.
    // Index mapping: [0]=TP9, [1]=AF7, [2]=AF8, [3]=TP10
    private var lastHsiRaw: [Double] = []
    // B83 — last NON-EMPTY HSI vector. The Combine `hsiRaw` publisher fires only after
    // the first SDK callback; before that, `self.hsiRaw == []` and per-sample contactState
    // fields land as nil → `undefined` in NDJSON (B82 instrumentation gap).
    // `lastValidHsi` retains the last 4-element vector seen, never resets on connect.
    private var lastValidHsi: [Double] = []
    // B83 — UI-stable HSI tier per channel. 4-of-5 sliding majority on rounded HSI tier
    // (1=good, 2=mediocre, 4=bad). Suppresses single-sample chip flicker that triggered
    // user complaint "TP9/TP10 keep going green/yellow." 5 samples × 1 Hz = ≤5 s latency.
    @Published var hsiStableTier: [Int] = [1, 1, 1, 1]
    private var hsiBuffer: [[Int]] = [[], [], [], []]
    // B83 — UI render counters; incremented by view bodies, drained by 30s appendUIState.
    @Published var timerHudRendered: Int = 0
    @Published var depthGaugeRendered: Int = 0
    @Published var chipViewRendered: Int = 0
    // B83 (B81 carryover) — pre-session fit-stability gate. Counts consecutive seconds
    // with all 4 contacts good. Banner dismisses when ≥5; reappears if any contact flips.
    @Published var consecutiveGoodSeconds: Int = 0
    private var lastFitGoodTick: Date = .distantPast
    private var lastRouteChangeAt: Date = .distantPast
    // B83 — periodic audioState + uiState logger. Fires every 30s while recording.
    private var diagnosticsTimer: Timer?
    private var sessionStart = Date()
    private var reconnectAttempts = 0
    // B80 (B2): grace-period state — when a BLE drop occurs mid-session we don't
    // immediately end the session. We wait up to 30s for the headband to reconnect.
    // If reconnect succeeds: session continues, gap is recorded.
    // If grace expires: session ends cleanly with what we have.
    @Published var isPausedForReconnect: Bool = false
    private var gracePeriodWork: DispatchWorkItem?
    private var gracePeriodStarted: Date?
    // Session summary shown after disconnect if session was recorded.
    @Published var sessionSummary: SessionRecord? = nil
    // B76 had a 300s recording delay after calibration; B77 records from calibration end and
    // tags first 300s as "warmup" instead. No data loss; analysis can still filter warmup.
    private var recordingStartWork: DispatchWorkItem?  // legacy field; kept to avoid wider refactor
    private var calibrationFiredRecording = false
    // Wall-clock time when SessionRecorder.startSession was called this connection.
    private var recordingStartedAt: Date? = nil
    // Read-only access for views that need session-relative timestamps for tap-to-mark.
    var recordingStartedAtForUI: Date? { recordingStartedAt }
    // Last time the beta-wander cue fired — 30s minimum gap.
    private var lastBetaCueDate = Date.distantPast

    func start() {
        // B77.2: cache IXNMuse objects so connectFirst() can connect without re-polling
        // getMuses(). Also drives pendingConnect: if list was empty when user tapped,
        // this sink fires doConnect() the moment museListChanged() delivers a Muse.
        client.discoveredMuses
            .receive(on: RunLoop.main)
            .sink { [weak self] museList in
                guard let self else { return }
                self.discoveredMuseObjects = museList
                self.muses = museList.compactMap { $0.getName() }
                if self.pendingConnect, let m = museList.first {
                    self.pendingConnect = false
                    self.doConnect(to: m)
                }
            }
            .store(in: &bag)

        client.connectionState
            .map { s -> String in
                switch s {
                case .unknown:      return "Unknown"
                case .connecting:   return "Connecting…"
                case .connected:    return "Connected"
                case .disconnected: return "Disconnected"
                case .needsUpdate:  return "Needs Update"
                @unknown default:   return "State \(s.rawValue)"
                }
            }
            .receive(on: RunLoop.main)
            .assign(to: &$connection)

        client.connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    Telemetry.connection.notice("connected at \(Date(), privacy: .public)")
                    UIApplication.shared.isIdleTimerDisabled = true
                    self?.connectingTimeoutWork?.cancel()
                    self?.connectingTimeoutWork = nil
                    self?.isConnecting = false
                    self?.pendingConnect = false
                    // B80 (B2): if we reconnected within the 30s grace period,
                    // resume the session rather than starting fresh.
                    if self?.isPausedForReconnect == true {
                        let graceDuration = Date().timeIntervalSince(self?.gracePeriodStarted ?? Date())
                        self?.gracePeriodWork?.cancel()
                        self?.gracePeriodWork = nil
                        self?.isPausedForReconnect = false
                        self?.gracePeriodStarted = nil
                        self?.reconnectAttempts = 0
                        // Resume soundscape: unduck restores volume if layers are still fading
                        // (reconnect < 2s into grace). If layers already stopped (reconnect > 2s),
                        // user will need to re-enable soundscape from the UI — we cannot
                        // auto-restart without knowing which layers were active.
                        SoundscapePlayer.shared.unduck(fadeDuration: 3.0)
                        // Record the gap in the session timeline
                        SessionRecorder.shared.recordGap(reason: "ble-drop", durationSec: graceDuration)
                        // Alert user that session is back
                        AlertCoordinator.shared.sessionResumed()
                        Telemetry.connection.notice("grace reconnect succeeded after \(String(format: "%.1f", graceDuration), privacy: .public)s")
                        return
                    }
                    self?.sessionStart = Date()
                    self?.sampleIndex  = 0
                    self?.bandHistory  = []
                    self?.reconnectAttempts = 0
                    self?.sessionSummary = nil
                    // Recording starts at calibration completion (B77: no 300s delay; warmup tag).
                    self?.calibrationFiredRecording = false
                    self?.recordingStartWork?.cancel()
                    self?.recordingStartedAt = nil
                    self?.lastBetaCueDate = .distantPast
                    // B80(C): reset diagnostic counters and start liveness watchdog.
                    self?.sessionDiagCounters = SessionDiagCounters()
                    self?.sessionEvents = []
                    self?.fitEventCount = 0
                    self?.lastHsiRaw = []
                    LivenessWatchdog.shared.start()
                    // B83 — clear sidecar denoise window buffer. New session = clean state.
                    EEGWindowBuffer.shared.reset()
                    // B80(D): cancel any leftover session timer from prior connection.
                    SessionTimer.shared.cancel()
                case .disconnected:
                    let wasRecording = SessionRecorder.shared.isRecording
                    let reconnAttempts = self?.reconnectAttempts ?? 0
                    Telemetry.connection.error("disconnected at \(Date(), privacy: .public) wasRecording=\(wasRecording, privacy: .public) reconnectAttempts=\(reconnAttempts, privacy: .public)")
                    UIApplication.shared.isIdleTimerDisabled = false
                    self?.connectingTimeoutWork?.cancel()
                    self?.connectingTimeoutWork = nil
                    self?.isConnecting = false
                    self?.pendingConnect = false
                    let stats: (count30s: Int, lastPacketAge: TimeInterval) = self?.client.eegPacketRollingStats() ?? (count30s: 0, lastPacketAge: 0)
                    Telemetry.eeg.error("post-disconnect packets-last-30s=\(stats.count30s, privacy: .public) lastPacketAge=\(stats.lastPacketAge, privacy: .public)s")
                    // B80 (B2): if a session is active, enter 30s grace period instead of
                    // immediately ending. Soundscape stops (2s fade), alert fires, reconnect
                    // is scheduled. If headband comes back within 30s the session continues.
                    if wasRecording, self?.isPausedForReconnect == false {
                        self?.isPausedForReconnect = true
                        self?.gracePeriodStarted = Date()
                        // Fade soundscape to silence — abrupt stop would be jarring
                        SoundscapePlayer.shared.stopAll(fadeSeconds: 2.0)
                        AlertCoordinator.shared.sessionPaused(reason: .bleDrop)
                        Telemetry.connection.notice("entering 30s grace period")
                        // Schedule 30s grace expiry
                        let gracework = DispatchWorkItem { [weak self] in
                            guard let self, self.isPausedForReconnect else { return }
                            self.isPausedForReconnect = false
                            self.gracePeriodWork = nil
                            let started = self.gracePeriodStarted
                            self.gracePeriodStarted = nil
                            Telemetry.connection.error("grace period expired — ending session")
                            // Fully end session with whatever we have
                            self.performFinalDisconnect(gracePeriodStart: started)
                            AlertCoordinator.shared.sessionEndedFailure(reason: "BLE reconnect timeout")
                        }
                        self?.gracePeriodWork = gracework
                        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: gracework)
                        self?.scheduleReconnect()
                        return
                    }
                    // Not recording (or already in grace period): standard disconnect path.
                    // Stop soundscape (missing before B80 — soundscape kept playing after disconnect).
                    SoundscapePlayer.shared.stopAll(fadeSeconds: 1.0)
                    self?.calibrationFiredRecording = false
                    self?.recordingStartWork?.cancel()
                    self?.recordingStartWork = nil
                    self?.recordingStartedAt = nil
                    // B80(D): cancel session-length timer (session is ending here, no grace).
                    SessionTimer.shared.cancel()
                    // B80: stop liveness watchdog, increment disconnect counter, log event.
                    LivenessWatchdog.shared.stop()
                    self?.sessionDiagCounters.disconnectCount += 1
                    self?.recordEvent(kind: "disconnect")
                    // Attach diagnostics before endSession so the saved file carries them.
                    if let s = self {
                        SessionRecorder.shared.attachDiagnostics(
                            s.buildDiagnostics(endReason: "disconnect-grace-expired"))
                        SessionRecorder.shared.attachEventStream(s.sessionEvents)
                    }
                    Telemetry.recording.error("endSession reason=disconnect")
                    let recUrl = SessionRecorder.shared.endSession(reason: "disconnect")
                    self?.pipeline.endSession()
                    self?.hrv.reset()
                    self?.rmssd     = nil
                    self?.lfhfRatio = nil
                    // Decode saved session on main thread. Typical session JSON ≤ 400 KB
                    // (2 Hz × 3600 s × ~50 B/sample) → decode < 20 ms. Acceptable at session end.
                    // Backgrounding would race with scheduleReconnect (fires 3 s later) which
                    // clears sessionSummary — synchronous decode is simpler and safe here.
                    if let url = recUrl,
                       let data = try? Data(contentsOf: url) {
                        let dec = JSONDecoder()
                        dec.dateDecodingStrategy = .iso8601
                        if let rec = try? dec.decode(SessionRecord.self, from: data) {
                            self?.sessionSummary = rec
                            // Successful = had deep state AND ≥5 min recorded.
                            if !rec.episodes.isEmpty && rec.durationMinutes >= 5.0 {
                                SoundscapePlayer.shared.decrementBinauralFade(
                                    latencyToFirstDeep: rec.episodes.first?.enterTime)
                            }
                            self?.computeSessionAnalytics()
                        }
                    }
                    self?.scheduleReconnect()
                default: break
                }
            }
            .store(in: &bag)

        client.fitCheck
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                guard let self else { return }
                let wasGood = self.fit.allGood
                self.fit = snap
                // B77.1: gauge/gate gate on FRONTAL contacts (AF7+AF8) only.
                // TP9/TP10 (ear) flicker on Athena even with good fit; using allGood
                // pinned the gauge in contact-loss decay mode for the entire session.
                self.gate.frontalContactGood = snap.frontalGood
                // B77.2: propagate frontal contact quality to EEGPipeline so the
                // aperiodic fit cache isn't updated from bad-contact windows.
                self.pipeline.frontalContactGood = snap.frontalGood
                // Gate contact chimes behind calibration: during 60s settle-in the headband
                // frequently fluctuates between good/bad contact. Chiming before calibration
                // completes is noisy and unhelpful — user can see contact state via dots.
                guard self.depth.isCalibrated else { return }
                // Post-calibration: record fit events for data, never play contact audio.
                // Dots give visual state — audio mid-sit breaks concentration regardless
                // of which contacts fluctuate (TP9/TP10 are rarely simultaneously green).
                if wasGood && !snap.allGood {
                    SessionRecorder.shared.addFitEvent(hsi: self.lastValidHsi, allGood: snap.allGood)
                    self.fitEventCount += 1   // B83 — parallel counter for grade metric
                }
                // B83 round-4 — fit-stability counter is INSTANTLY reset on flip→bad here,
                // but the per-second INCREMENT is driven by `pipeline.onBandPowers` (2 Hz),
                // not this sink. Reason: `client.fitCheck` is a CurrentValueSubject and
                // only fires on snapshot CHANGE — during steady allGood it would never
                // tick, freezing the banner. Round-3 fix had this wrong.
                if !snap.allGood {
                    self.consecutiveGoodSeconds = 0
                    self.lastFitGoodTick = .distantPast
                }
            }
            .store(in: &bag)

        client.battery
            .receive(on: RunLoop.main)
            .assign(to: &$battery)

        // B80: configure liveness watchdog callback before subscribing to eegPacket.
        LivenessWatchdog.shared.onStallDetected = { [weak self] gap in
            DispatchQueue.main.async {
                guard let self else { return }
                Telemetry.eeg.error("EEG stall detected gap=\(String(format: "%.2f", gap), privacy: .public)s — scheduling reconnect check")
                let t = self.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                self.sessionDiagCounters.stallEvents.append(StallEvent(time: t, gap: gap))
                self.recordEvent(kind: "stall", detail: String(format: "gap=%.2fs", gap))
            }
        }

        client.eegPacket
            .receive(on: RunLoop.main)
            .sink { [weak self] pkt in
                guard let self else { return }
                self.lastEEG = pkt.channels
                self.packetCount += 1
                self.pipeline.process(pkt)
                // B80: notify liveness watchdog of every raw packet.
                LivenessWatchdog.shared.packetReceived()
            }
            .store(in: &bag)

        client.hsiRaw
            .receive(on: RunLoop.main)
            .sink { [weak self] vals in
                guard let self else { return }
                self.hsiCount += 1
                self.hsiRaw = vals
                // B83 — retain last non-empty vector for addSample. Survives reconnect.
                if vals.count == 4 {
                    self.lastValidHsi = vals
                    // B83 — 4-of-5 sliding-majority hysteresis per channel for UI display.
                    // SDK tiers: 1=good, 2=mediocre, 4=bad. Round and append.
                    for i in 0..<4 {
                        let tier = Int(vals[i].rounded())
                        self.hsiBuffer[i].append(tier)
                        if self.hsiBuffer[i].count > 5 {
                            self.hsiBuffer[i].removeFirst(self.hsiBuffer[i].count - 5)
                        }
                        // 4-of-5 majority: only flip stable tier when ≥4 of last 5 agree.
                        var counts: [Int: Int] = [:]
                        for v in self.hsiBuffer[i] { counts[v, default: 0] += 1 }
                        if let (best, n) = counts.max(by: { $0.value < $1.value }), n >= 4 {
                            if self.hsiStableTier[i] != best {
                                self.hsiStableTier[i] = best
                            }
                        }
                    }
                }
                // B80: detect per-channel HSI state transitions.
                // HSI vals index: [0]=TP9, [1]=AF7, [2]=AF8, [3]=TP10
                // Threshold: < 2.0 = good (1), >= 2.0 & < 4.0 = mediocre (2), >= 4.0 = bad (4)
                let channelNames = ["TP9", "AF7", "AF8", "TP10"]
                let prev = self.lastHsiRaw
                if prev.count == 4 {
                    for i in 0..<4 {
                        let oldVal = prev[i]
                        let newVal = vals[i]
                        // Transition detected: good→bad or bad→good (any crossing)
                        let oldGood = oldVal < 2.0
                        let newGood = newVal < 2.0
                        if oldGood != newGood {
                            let ch = channelNames[i]
                            self.sessionDiagCounters.contactStateChanges[ch, default: 0] += 1
                            let kind = newGood ? "contact-restored-\(ch)" : "contact-loss-\(ch)"
                            self.recordEvent(kind: kind)
                        }
                    }
                }
                self.lastHsiRaw = vals
            }
            .store(in: &bag)

        pipeline.onBandPowers = { [weak self] powers, correctedPowers in
            guard let self else { return }
            // B83 round-4 — drive `consecutiveGoodSeconds` from band-power callbacks
            // (~2 Hz steady) so the fit-stability banner ticks even during stable allGood
            // periods. Increments only when fit.allGood AND ≥1 s elapsed since last tick.
            // Reset to 0 happens in the fit sink the moment allGood flips.
            if self.fit.allGood {
                let now = Date()
                if now.timeIntervalSince(self.lastFitGoodTick) >= 1.0 {
                    self.consecutiveGoodSeconds += 1
                    self.lastFitGoodTick = now
                }
            }
            let frontal = powers.filter { [1, 2].contains($0.channel) }
            if !frontal.isEmpty {
                let n = Float(frontal.count)
                let alpha = frontal.map(\.alpha).reduce(0, +) / n
                let theta = frontal.map(\.theta).reduce(0, +) / n
                let beta  = frontal.map(\.beta).reduce(0, +)  / n
                let delta = frontal.map(\.delta).reduce(0, +) / n
                let gamma = frontal.map(\.gamma).reduce(0, +) / n
                let alphaPeak = frontal.map(\.alphaPeak).reduce(0, +) / n
                let thetaPeak = frontal.map(\.thetaPeak).reduce(0, +) / n
                let betaPeak  = frontal.map(\.betaPeak).reduce(0, +)  / n
                let deltaPeak = frontal.map(\.deltaPeak).reduce(0, +) / n
                let gammaPeak = frontal.map(\.gammaPeak).reduce(0, +) / n
                let af7Alpha  = powers.first(where: { $0.channel == 1 })?.alpha ?? 0
                let af8Alpha  = powers.first(where: { $0.channel == 2 })?.alpha ?? 0
                let faa       = af8Alpha - af7Alpha
                self.frontAlpha = alpha
                self.frontTheta = theta
                self.frontBeta  = beta
                self.frontDelta = delta
                self.frontGamma = gamma
                self.bandUpdateCount += 1
                let sample = BandSample(
                    id: self.sampleIndex,
                    time: Date().timeIntervalSince(self.sessionStart),
                    alpha: alpha, theta: theta, beta: beta, delta: delta, gamma: gamma,
                    alphaPeak: alphaPeak, thetaPeak: thetaPeak, betaPeak: betaPeak,
                    deltaPeak: deltaPeak, gammaPeak: gammaPeak,
                    faa: faa
                )
                self.sampleIndex += 1
                self.bandHistory.append(sample)
                if self.bandHistory.count > 120 { self.bandHistory.removeFirst() }
            }
            self.scorer.process(powers, correctedPowers: correctedPowers)
            // Beta wander alert: fires when frontal beta is >1.5 SD above resting baseline
            // AND depth is shallow (<0.3). Trains awareness of mind-wandering without jarring
            // the session — uses additive log threshold since frontBeta is in log10 µV².
            // D4: Beta wander alert — ECDF gating replaces raw depth.score < 0.3.
            // gate.smoothedDisplay is the B77 ECDF-mapped display value [0,1]:
            //   properly distributed across the user's personal history.
            //   Raw depth.score < 0.3 was nearly always false (ECDF centering fixed this).
            // Diagnostic log fires every time gate1 passes — reveals why beta cue wasn't firing.
            if self.depth.isCalibrated && self.betaCueEnabled {
                let bm = self.scorer.calibrationBetaMean
                let bs = self.scorer.calibrationBetaStd
                let g1_threshold = bs > 0 && self.frontBeta > bm + 1.5 * bs
                let g2_shallow_ecdf = self.gate.smoothedDisplay < 0.3  // B77 ECDF map [0,1] — properly distributed
                if g1_threshold {
                    Telemetry.recording.notice("beta-cue gate1=true gate2=\(g2_shallow_ecdf, privacy: .public) ecdf=\(self.gate.smoothedDisplay, privacy: .public) rawDepth=\(self.depth.score, privacy: .public)")
                    if g2_shallow_ecdf {
                        let now = Date()
                        if now.timeIntervalSince(self.lastBetaCueDate) >= 30.0 {
                            self.lastBetaCueDate = now
                            ChimeEngine.shared.playBetaCue()
                        }
                    }
                }
            }
            // Record after scorer.process so depth reflects current frame.
            // B77: warmup phase = first 300s post-calibration. Tagged but no longer skipped.
            let phase: String? = {
                guard let started = self.recordingStartedAt else { return nil }
                return Date().timeIntervalSince(started) < 300 ? "warmup" : "main"
            }()
            let elem = self.elements.values
            // B83 — read from lastValidHsi (retainer) instead of hsiRaw (Combine race).
            // hsi index: [0]=TP9 [1]=AF7 [2]=AF8 [3]=TP10. Round to integer (1/2/4 tiers).
            // B82 NDJSON had every contactState field undefined because hsiRaw was
            // empty when the very first sample built. lastValidHsi survives.
            let hsi = self.lastValidHsi
            let hsiAF7  = hsi.count > 1 ? Int(hsi[1].rounded()) : nil
            let hsiAF8  = hsi.count > 2 ? Int(hsi[2].rounded()) : nil
            let hsiTP9  = hsi.count > 0 ? Int(hsi[0].rounded()) : nil
            let hsiTP10 = hsi.count > 3 ? Int(hsi[3].rounded()) : nil
            // B83 — packet gap from MuseClient atomic counter (updated on every SDK
            // callback). LivenessWatchdog's lastGap was sometimes stale at sample time.
            let gapRaw: Float = MuseClient.lastPacketGapMs
            let gapMs: Float? = gapRaw > 0 ? gapRaw : nil
            let battFrac: Float? = self.battery > 0 ? Float(self.battery / 100.0) : nil
            let orientStr: String = {
                switch UIDevice.current.orientation {
                case .portrait:           return "portrait"
                case .landscapeLeft, .landscapeRight: return "landscape"
                case .faceUp:             return "faceUp"
                case .faceDown:           return "faceDown"
                default:                  return "portrait"
                }
            }()
            let appStateStr: String = {
                switch UIApplication.shared.applicationState {
                case .active:      return "active"
                case .background:  return "background"
                case .inactive:    return "inactive"
                @unknown default:  return "active"
                }
            }()
            SessionRecorder.shared.addSample(
                alpha: self.frontAlpha, theta: self.frontTheta,
                beta:  self.frontBeta,  delta: self.frontDelta,
                gamma: self.frontGamma, depth: self.depth.score,
                inDeep: self.gate.inDeepState,
                heartRateBPM: self.heartRate > 0 ? Float(self.heartRate) : nil,
                faa: self.depth.faa,
                aperiodicSlopeMean: self.aperiodicSlope,
                iTPFFrontal: self.iTPFFrontal,
                rmssd: self.rmssd,
                lfhfRatio: self.lfhfRatio,
                meditationIndex:          self.depth.meditationIndex,
                meditationIndexCorrected: self.depth.meditationIndexCorrected,
                depthZ:        self.depth.z,
                ecdfDisplay:   self.gate.smoothedDisplay,
                alphaRel:      elem.alphaRelative.isFinite ? elem.alphaRelative : nil,
                thetaRel:      elem.thetaRelative.isFinite ? elem.thetaRelative : nil,
                betaRel:       elem.betaRelative.isFinite  ? elem.betaRelative  : nil,
                alphaScoreSDK: elem.alphaScore.isFinite    ? elem.alphaScore    : nil,
                thetaScoreSDK: elem.thetaScore.isFinite    ? elem.thetaScore    : nil,
                betaScoreSDK:  elem.betaScore.isFinite     ? elem.betaScore     : nil,
                phase:         phase,
                frontalGood:   self.fit.frontalGood,
                // B80 diagnostic fields
                contactStateAF7:  hsiAF7,
                contactStateAF8:  hsiAF8,
                contactStateTP9:  hsiTP9,
                contactStateTP10: hsiTP10,
                packetGapMs:      gapMs,
                appState:         appStateStr,
                batteryLevel:     battFrac,
                phoneOrientation: orientStr
            )
        }

        scorer.onResult = { [weak self] result in
            guard let self else { return }
            self.depth = result
            self.gate.update(result)
            SoundscapePlayer.shared.updateAdaptiveDepth(result.score, iTPF: self.iTPFFrontal)
            // B77: record from calibration end (no 300s delay). First 300s tagged "warmup"
            // in addSample so analysis can still filter, but data is preserved.
            if result.isCalibrated && !self.calibrationFiredRecording {
                self.calibrationFiredRecording = true
                self.recordingStartWork?.cancel()
                self.recordingStartedAt = Date()
                self.marks.reset()
                ElementsTracker.shared.reset()
                PersonalZDistribution.shared.resetSessionRing()
                SessionRecorder.shared.startSession(
                    calibrationIndexMean: self.scorer.calibrationIndexMean,
                    calibrationIndexStd:  self.scorer.calibrationIndexStd
                )
                // B83 — start main-thread stall detector (1Hz heartbeat, 1.5s threshold).
                // Quantifies the "freezing" sensation users describe; emits `mainStall` events.
                MainThreadStall.shared.start()
                // B83 — periodic 30s diagnostics: audioState + uiState snapshot.
                // Drains UI render counters, captures AVAudioSession + engine state,
                // route info, chime volume. Fires the very first one immediately so
                // we capture state at session start, not 30s in.
                self.diagnosticsTimer?.invalidate()
                self.fireDiagnosticsSnapshot(trigger: "session-start")
                self.diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    self?.fireDiagnosticsSnapshot(trigger: "periodic")
                }
                if let dt = self.diagnosticsTimer { RunLoop.main.add(dt, forMode: .common) }
                // D1: Start session-length auto-timer.
                // Timer fires endSessionGracefully(reason:) on expiry.
                SessionTimer.shared.start()
                SessionTimer.shared.onExpire = { [weak self] in
                    Telemetry.recording.notice("timer expired at \(SessionTimer.shared.selectedDurationMin, privacy: .public)min")
                    self?.recordEvent(kind: "timer-expired",
                                      detail: "\(SessionTimer.shared.selectedDurationMin)min")
                    self?.endSessionGracefully(reason: "timer-completed")
                }
            }
        }

        pipeline.onAperiodicUpdate = { [weak self] chi in
            DispatchQueue.main.async { self?.aperiodicSlope = chi }
        }

        // onAperiodicFitUpdate: full fit (chi+offset+R²) used internally by EEGPipeline
        // to drive AperiodicCorrection. Probe doesn't need to consume it directly.

        pipeline.onITPFUpdate = { [weak self] iTPF in
            DispatchQueue.main.async { self?.iTPFFrontal = iTPF }
        }

        // HRV: feed raw Optics7/8 mean samples to HRVPipeline on SDK callback thread.
        // process() dispatches to hrv.queue internally; sink overhead on calling thread is minimal.
        client.opticsRawSample
            .sink { [weak self] s in self?.hrv.process(s) }
            .store(in: &bag)

        hrv.onRMSSD = { [weak self] rmssd, lfhf in
            self?.rmssd     = Float(rmssd)
            self?.lfhfRatio = lfhf.map { Float($0) }
        }

        client.artifactDetected
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.depth.isCalibrated else { return }
                self.pipeline.suppressArtifact()
            }
            .store(in: &bag)

        client.heartRate
            .receive(on: RunLoop.main)
            .assign(to: &$heartRate)

        // B80 (B3): Configure AVAudioSession for background audio playback.
        // .playback category + .mixWithOthers allows soundscape to continue when screen locks.
        // Combined with UIBackgroundModes: audio in Info.plist (set in project.yml).
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            Telemetry.audio.notice("AVAudioSession configured: category=playback mixWithOthers")
        } catch {
            Telemetry.audio.error("AVAudioSession configure failed: \(error.localizedDescription, privacy: .public)")
        }

        // B80 (B3): AVAudioSession interruption handling — active response.
        // On .began: immediately pause soundscape (abrupt OK — system interrupted us).
        // On .ended+shouldResume: resume soundscape.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let info = note.userInfo,
                      let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
                Telemetry.audio.error("interruption type=\(typeVal, privacy: .public) at \(Date(), privacy: .public)")
                // B80(C): count audio interruptions and log event.
                self?.sessionDiagCounters.audioInterruptions += 1
                self?.recordEvent(kind: "audio-interrupt", detail: "type=\(typeVal)")
                // B80(B): handle interrupt lifecycle — pause/resume soundscape and alert user.
                switch type {
                case .began:
                    // Abrupt duck — system has taken audio session; our engine is silenced anyway.
                    SoundscapePlayer.shared.duck(to: 0.0, fadeDuration: 0.0)
                    if SessionRecorder.shared.isRecording {
                        AlertCoordinator.shared.sessionPaused(reason: .audioInterruption)
                    }
                case .ended:
                    // Only resume if system says we should.
                    let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                        .map { $0.contains(.shouldResume) } ?? false
                    if shouldResume {
                        // Re-activate session before resuming (system may have deactivated it)
                        try? AVAudioSession.sharedInstance().setActive(true, options: [])
                        SoundscapePlayer.shared.unduck(fadeDuration: 2.0)
                        if SessionRecorder.shared.isRecording {
                            AlertCoordinator.shared.sessionResumed()
                        }
                    }
                @unknown default:
                    break
                }
            }
            .store(in: &bag)

        // B80 (B3): Route change — log only. Engine handles reconnect via AVAudioEngineConfigurationChange.
        // B83 — also stamp `lastRouteChangeAt` so audioState snapshots can answer
        // "was the gong scheduled within N seconds of a route change?" — a known
        // class of AVAudioPlayerNode silent-render bug.
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let info = note.userInfo,
                      let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
                Telemetry.audio.notice("route change reason=\(reasonVal, privacy: .public) at \(Date(), privacy: .public)")
                self?.lastRouteChangeAt = Date()
                self?.sessionDiagCounters.routeChanges += 1
                self?.recordEvent(kind: "route-change", detail: "reason=\(reasonVal)")
                // Snapshot audio state on every route change.
                self?.fireDiagnosticsSnapshot(trigger: "route-change")
            }
            .store(in: &bag)

        // B80 (B5): Background/foreground lifecycle — log only.
        // BLE + audio remain alive via bluetooth-central + audio background modes + .playback category.
        // We deliberately do NOT pause anything on backgrounding — that would defeat the purpose.
        // UIApplication.shared.isIdleTimerDisabled = true (set on .connected) prevents auto-lock
        // during active sessions. User manual lock is NOT preventable; see STATUS.md invariants.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                Telemetry.connection.notice("app entered background — BLE+audio background modes active")
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { _ in
                Telemetry.connection.notice("app entering foreground")
            }
            .store(in: &bag)

        // B80: Request notification authorization for AlertCoordinator (once per launch).
        Task { await AlertCoordinator.shared.requestAuthorization() }

        client.startScan()
    }

    // UserDefaults-backed toggle: default true. No @Published needed — Settings reads inline.
    var betaCueEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "betaCueEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "betaCueEnabled") }
    }

    // D3: Published flag observed by MeditationView to show "Session saved" toast.
    @Published var sessionSavedToast: String? = nil

    // D1+D2+D3: Graceful session end — plays gong, fades soundscape, saves recording, shows toast.
    // reason: "timer-completed" | "manual" | "timer-during-reconnect"
    // Cross-agent note: Agent B may add isPausedForReconnect to Probe.
    // When present, we still proceed but tag the end reason so B's grace-period logic is informed.
    func endSessionGracefully(reason: String) {
        // If Agent B's reconnect grace is active, mark reason but proceed.
        // isPausedForReconnect checked via optional chaining; property added by Agent B.
        // let effectiveReason = isPausedForReconnect ? "timer-during-reconnect" : reason
        let effectiveReason = reason  // simplified until Agent B lands isPausedForReconnect
        Telemetry.recording.notice("endSessionGracefully reason=\(effectiveReason, privacy: .public)")
        SessionTimer.shared.cancel()
        // B83 — capture audio state at gong time. The MOST important snapshot for
        // debugging audibility; without this we can't tell whether the speaker had
        // output enabled when the gong fired.
        fireDiagnosticsSnapshot(trigger: "endSession-pre-gong")
        // B83 — route to EndGongPlayer. If `bowl_success.{m4a,wav}` is bundled, plays the
        // recorded sample via AVAudioPlayer (file-based, immune to engine state). Otherwise
        // falls back to ChimeEngine.playGong() — now at 432 Hz fundamental (audible on
        // iPhone built-in speaker, unlike the old 84 Hz that B82 instrumentation will prove
        // was sub-resonant if outputs included only `builtInSpeaker`).
        EndGongPlayer.shared.playSuccess()
        // B83 — record the manual/timer end as event in NDJSON.
        recordEvent(kind: "session-end-success", detail: effectiveReason)
        // Fade soundscape over 4s (gong plays concurrently per task spec).
        SoundscapePlayer.shared.stopAll(fadeSeconds: 4.0)
        MainThreadStall.shared.stop()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        recordingStartWork?.cancel()
        // B80(C): attach diagnostics before endSession so they're included in the saved file.
        SessionRecorder.shared.attachDiagnostics(buildDiagnostics(endReason: effectiveReason))
        SessionRecorder.shared.attachEventStream(sessionEvents)
        Telemetry.recording.notice("endSession reason=\(effectiveReason, privacy: .public)")
        let recUrl = SessionRecorder.shared.endSession(reason: effectiveReason)
        pipeline.endSession()
        hrv.reset()
        rmssd     = nil
        lfhfRatio = nil
        if let url = recUrl,
           let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let rec = try? dec.decode(SessionRecord.self, from: data) {
                sessionSummary = rec
                sessionSavedToast = "Session saved"
                return
            }
        }
        // Recording hadn't started — show empty summary + toast
        let now = Date()
        sessionSummary = SessionRecord(id: UUID().uuidString, startDate: now, endDate: now,
                                       samples: [], episodes: [], fitEvents: [])
        sessionSavedToast = "Session saved"
    }

    // Manual session end from UI — routes through endSessionGracefully for gong + toast.
    // Does NOT disconnect the headband; visual feedback continues.
    func manualEndSession() {
        endSessionGracefully(reason: "manual")
    }

    // True from the moment connectFirst() is called until connectionState reaches
    // .connected or .disconnected. Prevents the connect button from spamming the SDK
    // with multiple connect() calls if the user double-taps during the BLE handshake.
    @Published var isConnecting: Bool = false
    // B77.2: cached IXNMuse objects from the last museListChanged() callback.
    // Avoids re-calling getMuses() at connect time (which can briefly return empty
    // even when a Muse was just displayed in the UI).
    private var discoveredMuseObjects: [IXNMuse] = []
    // B77.2: set when connectFirst() fires before a Muse has appeared in the scan list.
    // The discoveredMuses sink calls doConnect() when museListChanged() delivers one.
    private var pendingConnect = false
    // B77.2: 15s watchdog — clears isConnecting if BLE handshake never fires .connected
    // or .disconnected. Prevents the button staying permanently in spinner state if the
    // SDK silently fails (e.g., headband out of range after getMuses() returned it).
    private var connectingTimeoutWork: DispatchWorkItem?

    func connectFirst() {
        guard !isConnecting, connection != "Connected" else { return }
        isConnecting = true
        let work = DispatchWorkItem { [weak self] in
            self?.isConnecting = false
            self?.pendingConnect = false
            self?.connectingTimeoutWork = nil
        }
        connectingTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        if let m = discoveredMuseObjects.first {
            // Muse already in cached list — connect without polling getMuses().
            doConnect(to: m)
        } else {
            // List currently empty (scan still in progress). Flag set; the discoveredMuses
            // sink will call doConnect() the moment museListChanged() delivers a Muse.
            pendingConnect = true
        }
    }

    private func doConnect(to muse: IXNMuse) {
        client.connect(to: muse)
        scorer.startCalibration()
        gate.reset()
        // B77: restore ECDF-space adaptive thresholds.
        let savedEnter = UserDefaults.standard.float(forKey: "adaptiveEnterEcdf")
        let savedExit  = UserDefaults.standard.float(forKey: "adaptiveExitEcdf")
        if savedEnter >= 0.50 && savedExit >= 0.40 {
            gate.setEcdfThresholds(enter: savedEnter, exit: savedExit)
        } else {
            gate.setEcdfThresholds(enter: 0.70, exit: 0.50)
        }
    }

    // Single-pass background analytics after each session end.
    // Computes three independent values from the session archive in one file pass:
    //   1. Adaptive deep threshold (75th pct of qualifying session means)
    //   2. Historical induction latency average (excludes current session for fair comparison)
    //   3. Daily practice streak (consecutive days with any session file)
    private func computeSessionAnalytics() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir  = docs.appendingPathComponent("MuseSessions")
            // Sorted descending: urls[0] = most recent (the session just ended)
            let allUrls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "json" }
              .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []

            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            var sessionMeans: [Float]    = []
            var latencies:    [Double]   = []

            for url in allUrls.prefix(30) {
                guard let data = try? Data(contentsOf: url),
                      let rec = try? dec.decode(SessionRecord.self, from: data),
                      !rec.episodes.isEmpty else { continue }
                sessionMeans.append(rec.meanDepth)
                if let lat = rec.episodes.first?.enterTime { latencies.append(lat) }
            }

            // 1. Adaptive ECDF-space threshold. Computes 75th pct of per-session mean ECDF
            // displays. With ECDF normalization the cross-session distribution is roughly
            // uniform, so 75th-pct of session means falls in [0.55, 0.80] range; enforce
            // [0.50, 0.85] to keep meaningful gate behavior.
            // Loads ecdfDisplay (B77+) when present; falls back to (depth-0.5)*2 for old
            // sessions so users with mixed history still get adaptation.
            var newEnterEcdf: Float? = nil
            if sessionMeans.count >= 5 {
                var ecdfMeans: [Float] = []
                for url in allUrls.prefix(30) {
                    guard let data = try? Data(contentsOf: url),
                          let rec = try? dec.decode(SessionRecord.self, from: data),
                          !rec.episodes.isEmpty else { continue }
                    let ecdfs = rec.samples.compactMap { $0.ecdfDisplay
                        ?? max(0, ($0.depth - 0.5) * 2.0) }
                    guard !ecdfs.isEmpty else { continue }
                    ecdfMeans.append(ecdfs.reduce(0, +) / Float(ecdfs.count))
                }
                if ecdfMeans.count >= 5 {
                    let sorted = ecdfMeans.sorted()
                    let p75 = sorted[min(Int(Double(sorted.count) * 0.75), sorted.count - 1)]
                    newEnterEcdf = max(0.50, min(0.85, p75))
                }
            }

            // 2. Historical induction latency: exclude current session (latencies[0]) for fair comparison.
            // We want "how does today compare to history" — including today biases toward today's result.
            var avgLatency: Double? = nil
            let historical = Array(latencies.dropFirst())  // everything except today's session
            if historical.count >= 3 {
                avgLatency = historical.reduce(0, +) / Double(historical.count)
            }

            // 3. Practice streak: consecutive calendar days with any session file
            let streak = Self.computeStreak(from: allUrls)

            DispatchQueue.main.async {
                if let t = newEnterEcdf {
                    let ex = max(0.40, t - 0.20)
                    self.gate.setEcdfThresholds(enter: t, exit: ex)
                    UserDefaults.standard.set(t,  forKey: "adaptiveEnterEcdf")
                    UserDefaults.standard.set(ex, forKey: "adaptiveExitEcdf")
                }
                if let avg = avgLatency {
                    UserDefaults.standard.set(avg, forKey: "avgInductionLatency")
                }
                UserDefaults.standard.set(streak, forKey: "meditationStreak")
            }
        }
    }

    // Counts consecutive days (going back from today) that contain at least one session file.
    // Filenames: session_YYYY-MM-dd_HHmm.json — date is the second component after splitting by "_".
    private static func computeStreak(from urls: [URL]) -> Int {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        var dates = Set<String>()
        for url in urls {
            let name  = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "_")
            if parts.count >= 2 { dates.insert(String(parts[1])) }
        }
        var streak = 0
        var day    = Date()
        while dates.contains(fmt.string(from: day)) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    // B80 (B2): Called when the 30s grace period expires without reconnect.
    // Tears down session state cleanly, preserves whatever was recorded.
    private func performFinalDisconnect(gracePeriodStart: Date?) {
        calibrationFiredRecording = false
        recordingStartWork?.cancel()
        recordingStartWork = nil
        recordingStartedAt = nil
        // B83 — capture audio state at failure-gong time.
        fireDiagnosticsSnapshot(trigger: "performFinalDisconnect-pre-gong")
        // B83 — was missing in B80; grace-expiry would silently end with NO audio cue.
        // EndGongPlayer.playFailure tries `bowl_failure.{m4a,wav}` then falls back to
        // ChimeEngine.playFailureChime (5 short alert pings, all in passband).
        EndGongPlayer.shared.playFailure()
        recordEvent(kind: "session-end-failure", detail: "grace-expired")
        // Lengthen the soundscape fade so it doesn't get cut off mid-gong.
        SoundscapePlayer.shared.stopAll(fadeSeconds: 4.0)
        MainThreadStall.shared.stop()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        Telemetry.recording.error("endSession reason=grace-expired")
        let recUrl = SessionRecorder.shared.endSession(reason: "grace-expired")
        pipeline.endSession()
        hrv.reset()
        rmssd     = nil
        lfhfRatio = nil
        if let url = recUrl,
           let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let rec = try? dec.decode(SessionRecord.self, from: data) {
                sessionSummary = rec
                if !rec.episodes.isEmpty && rec.durationMinutes >= 5.0 {
                    SoundscapePlayer.shared.decrementBinauralFade(
                        latencyToFirstDeep: rec.episodes.first?.enterTime)
                }
                computeSessionAnalytics()
            }
        }
    }

    private func reconnect() {
        if let m = IXNMuseManagerIos.sharedManager().getMuses().first {
            // preservePreset: headband already has the correct preset from user-initiated connect.
            // Re-applying it causes an extra disconnect/reconnect loop that delays EEG flow
            // and runs the calibration timer past 60s before any band powers arrive.
            client.connect(to: m, preservePreset: true)
        }
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < 3 else {
            reconnectAttempts = 0
            return
        }
        reconnectAttempts += 1
        // B80: track reconnect attempts for diagnostics.
        sessionDiagCounters.reconnectAttempts += 1
        recordEvent(kind: "reconnect", detail: "attempt \(reconnectAttempts)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.connection == "Disconnected" else {
                self?.reconnectAttempts = 0
                return
            }
            self.reconnect()
        }
    }

    // MARK: - B80 Diagnostic helpers
    //
    // recordEvent: call from ANY site (main thread assumed — all callers are on main).
    // kind strings: "disconnect","reconnect","stall","audio-interrupt","route-change",
    //   "contact-loss-AF7","contact-restored-AF7","contact-loss-AF8","contact-restored-AF8",
    //   "contact-loss-TP9","contact-restored-TP9","contact-loss-TP10","contact-restored-TP10",
    //   "app-background","app-foreground","timer-expired"
    // Agent B calls this from disconnect handler. Agent D calls it for "timer-expired".

    func recordEvent(kind: String, detail: String? = nil) {
        let t = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let ev = SessionEvent(time: t, kind: kind, detail: detail)
        sessionEvents.append(ev)
        // B83 — also write to NDJSON immediately. The B80 in-memory `sessionEvents`
        // attached only at endSession; if the app crashed mid-session, every event was
        // lost. NDJSON-streamed events survive crashes (matches B80 NDJSON-sample design).
        SessionRecorder.shared.appendEvent(ev)
    }

    /// B83 — capture AVAudioSession state, engine flags, and UI render counters.
    /// Called at session start, every 30s, and immediately before every gong/chime
    /// scheduling site (via `audioStateBeforeGong`).
    func fireDiagnosticsSnapshot(trigger: String) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { $0.portType.rawValue }
        // B83 round-4 — UserDefaults stores numeric values as NSNumber. The `as? Float`
        // cast fails when the underlying NSNumber holds a Double; falling back to 0.7
        // would mask a user who actually turned the volume DOWN. Read both Float and
        // Double then clamp.
        let chimeVol: Float = {
            let raw = UserDefaults.standard.object(forKey: "chimeVolume")
            if let f = raw as? Float  { return max(0, min(1, f)) }
            if let d = raw as? Double { return max(0, min(1, Float(d))) }
            if let n = raw as? NSNumber { return max(0, min(1, n.floatValue)) }
            return 0.7  // default if absent
        }()
        let secsSinceRoute: Int? = lastRouteChangeAt == .distantPast
            ? nil
            : Int(Date().timeIntervalSince(lastRouteChangeAt))
        SessionRecorder.shared.appendAudioState(
            trigger: trigger,
            outputVolume: session.outputVolume,
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            isOtherAudioPlaying: session.isOtherAudioPlaying,
            outputs: outputs,
            chimeEngineRunning: ChimeEngine.shared.isEngineRunning,
            chimeEnginePlayerPlaying: ChimeEngine.shared.isPlayerPlaying,
            soundscapeEngineRunning: SoundscapePlayer.shared.isEngineRunning,
            chimeVolumeSetting: chimeVol,
            secondsSinceLastRouteChange: secsSinceRoute
        )
        SessionRecorder.shared.appendUIState(
            trigger: trigger,
            timerHudRendered: timerHudRendered,
            depthGaugeRendered: depthGaugeRendered,
            chipViewRendered: chipViewRendered
        )
    }

    // buildDiagnostics: call immediately before endSession. Reads current counter snapshot
    // and computes packet gap stats from sample stream (mirrors SessionRecorder internal logic
    // for cross-validation; authoritative values come from the recorder's own log).
    // Must be called on main thread.

    func buildDiagnostics(endReason: String) -> SessionDiagnostics {
        let watchdog = LivenessWatchdog.shared.currentStats()
        let gapMean = watchdog.mean
        let gapP95  = gapMean + 1.645 * watchdog.std
        let gapMax  = max(watchdog.lastGap, gapMean + 3 * watchdog.std)

        let device = UIDevice.current
        let model  = device.model
        let iosVer = UIDevice.current.systemVersion

        // B83 — compute A/B/C/F headband-fit grade.
        // METRIC HONESTY (corrected from prior commit): Use FIT-event rate as the
        // primary signal, NOT HSI transition rate. Fit events fire when overall
        // `FitCheckSnapshot.allGood` flips good→bad — directly mirrors the user's
        // perceived headband-instability cadence. HSI transitions count per-channel
        // tier flips (1↔2, 1↔4) which are noisier and less aligned with user feel.
        // B82 reference: 210 fit events / 22.6 min = 9.3/min → grades C.
        let sessionMin: Double = {
            guard let started = recordingStartedAt else { return 0 }
            return Date().timeIntervalSince(started) / 60.0
        }()
        let fitsPerMin: Double = sessionMin > 0 ? Double(fitEventCount) / sessionMin : 0
        // Per-channel HSI transitions retained as secondary metric — surfaces in
        // contactStateChanges dict but not in the grade itself.
        let grade: String = {
            if sessionMin < 1.0 { return "—" }   // too short to grade
            if fitsPerMin <= 2  { return "A" }   // ≤2/min: rock solid
            if fitsPerMin <= 5  { return "B" }   // ≤5/min: minor wobble
            if fitsPerMin <= 10 { return "C" }   // ≤10/min: noticeable instability (B82 region)
            return "F"                           // >10/min: replace headband or reseat
        }()

        return SessionDiagnostics(
            packetGapMean:       gapMean,
            packetGapP95:        gapP95,
            packetGapMax:        gapMax,
            packetCount:         watchdog.packetCount,
            disconnectCount:     sessionDiagCounters.disconnectCount,
            reconnectAttempts:   sessionDiagCounters.reconnectAttempts,
            audioInterruptions:  sessionDiagCounters.audioInterruptions,
            routeChanges:        sessionDiagCounters.routeChanges,
            contactStateChanges: sessionDiagCounters.contactStateChanges,
            stallEvents:         sessionDiagCounters.stallEvents,
            endReason:           endReason,
            buildTag:            "B83",
            deviceModel:         model,
            iosVersion:          iosVer,
            museModel:           client.museModelString,
            contactQualityGrade: grade,
            fitEventsPerMin:     fitsPerMin
        )
    }
}

// MARK: - Root view

struct ProbeView: View {
    @ObservedObject var probe: Probe
    @State private var showSettings   = false
    @State private var showSoundscape = false
    @State private var showTimer      = false

    private var isConnected: Bool {
        probe.connection == "Connected"
    }

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()
            if isConnected {
                MeditationView(probe: probe,
                               showSettings:   $showSettings,
                               showSoundscape: $showSoundscape,
                               showTimer:      $showTimer)
            } else {
                ConnectView(probe: probe, showSettings: $showSettings)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings)   { SettingsSheet(probe: probe) }
        .sheet(isPresented: $showSoundscape) { SoundscapeSheet() }
        .sheet(isPresented: $showTimer)      { TimerSheet() }
        .sheet(item: $probe.sessionSummary)  { rec in
            SessionSummarySheet(record: rec) { probe.sessionSummary = nil }
        }
        // B80: recover any orphaned NDJSON files from previous crash, then load sessions.
        .onAppear {
            CrashRecovery.shared.recoverOrphans()
            SessionRecorder.shared.loadSavedSessions()
            // Schedule first background flush in case the app is backgrounded early.
            SessionRecorder.scheduleNextBackgroundFlush()
        }
        // B80: present one-time crash-recovery alert if sessions were recovered.
        .crashRecoveryAlert()
    }
}

// MARK: - Connect screen

private struct ConnectView: View {
    @ObservedObject var probe: Probe
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 32) {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 72))
                .foregroundStyle(.white.opacity(0.18))

            VStack(spacing: 8) {
                Text("Muse++")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Connect your headband to begin")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }

            if probe.muses.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(.white.opacity(0.5))
                    Text("Scanning…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.45))
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(probe.muses, id: \.self) { name in
                        ConnectMuseButton(name: name, probe: probe)
                    }
                }
                .padding(.horizontal, 28)
            }
            Spacer()
        }
    }
}

// MARK: - Connect-muse button with visual feedback

private struct ConnectMuseButton: View {
    let name: String
    @ObservedObject var probe: Probe
    @State private var pressed = false

    var body: some View {
        Button {
            // Immediate visual feedback so the user knows the tap registered. The
            // SDK connection handshake takes 500-2000ms and was previously silent.
            pressed = true
            probe.connectFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pressed = false }
        } label: {
            HStack {
                if probe.isConnecting {
                    ProgressView().tint(.white).scaleEffect(0.7)
                        .frame(width: 18)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                Text(name)
                    .fontWeight(.medium)
                Spacer()
                if probe.isConnecting {
                    Text("Connecting…").font(.caption).foregroundStyle(.white.opacity(0.5))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.white.opacity(pressed ? 0.20 : (probe.isConnecting ? 0.04 : 0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .scaleEffect(pressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: pressed)
            .animation(.easeOut(duration: 0.2),  value: probe.isConnecting)
        }
        .foregroundStyle(.white)
        .disabled(probe.isConnecting)
    }
}

// MARK: - Meditation main view

private struct MeditationView: View {
    @ObservedObject var probe: Probe
    @Binding var showSettings:   Bool
    @Binding var showSoundscape: Bool
    @Binding var showTimer:      Bool

    @State private var showEndConfirm = false
    @ObservedObject private var sessionTimer = SessionTimer.shared
    @ObservedObject private var sound = SoundscapePlayer.shared
    // D3: toast message — auto-cleared by ToastModifier after 3s
    @State private var toastMessage: String? = nil

    // χ color: green = deep absorption (steep slope), yellow = neutral, red/orange = aroused
    private func chiColor(_ chi: Float) -> Color {
        if chi < -1.5 { return Color(red: 0.20, green: 0.95, blue: 0.60) }
        if chi < -1.0 { return Color(red: 0.95, green: 0.85, blue: 0.20) }
        return Color(red: 0.95, green: 0.50, blue: 0.25)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(alignment: .center, spacing: 10) {
                SignalChipsView(fit: probe.fit, hsi: probe.hsiRaw, hsiStable: probe.hsiStableTier, probe: probe)
                Spacer()
                if probe.heartRate > 0 {
                    Label("\(Int(probe.heartRate.rounded())) bpm", systemImage: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.45).opacity(0.85))
                }
                if let chi = probe.aperiodicSlope {
                    Text("χ \(String(format: "%.2f", chi))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(chiColor(chi))
                }
                if probe.battery > 0 {
                    Label("\(Int(probe.battery))%", systemImage: "battery.75")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // B77: live SDK Elements diagnostic strip — exposes the components hidden behind
            // the unified depth score. Mellow/Concentration discontinued in 2016 because
            // unified scores were inaccurate; component visibility prevents that failure mode.
            if probe.depth.isCalibrated {
                ElementsStripView(probe: probe)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }

            // Scrollable body: takes all space between top bar and bottom controls.
            // ScrollView+frame(maxHeight:.infinity) is the correct SwiftUI pattern for
            // "fixed header, scrollable middle, fixed footer" — no GeometryReader needed.
            // On large iPhones content fits without scrolling; on small iPhones or when
            // all conditional views are shown the user can scroll to reach the band chart.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Pre-session fit-stability banner (B83/B81 carryover)
                    if !probe.depth.isCalibrated && probe.consecutiveGoodSeconds < 5 {
                        FitStabilityBannerView(consecutiveGood: probe.consecutiveGoodSeconds,
                                                fit: probe.fit)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }

                    // Hero depth gauge — 16pt top padding replaces the collapsing Spacer
                    DepthGaugeView(probe: probe)
                        .padding(.top, 16)

                    // Session-length countdown
                    if sessionTimer.isRunning {
                        let r = sessionTimer.remainingSec
                        let total = sessionTimer.selectedDurationMin * 60
                        let elapsed = total - r
                        VStack(spacing: 2) {
                            Text(String(format: "%d:%02d", r / 60, r % 60))
                                .font(.system(size: 28, weight: .light, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.88))
                            Text(String(format: "%d:%02d / %d:%02d  remaining",
                                        elapsed / 60, elapsed % 60, total / 60, total % 60))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.top, 8)
                        .onChange(of: r) { _, _ in
                            DispatchQueue.main.async { probe.timerHudRendered += 1 }
                        }
                    }

                    // Tap-to-mark row
                    if probe.depth.isCalibrated && SessionRecorder.shared.isRecording {
                        MarksRowView(probe: probe)
                            .padding(.horizontal, 28)
                            .padding(.top, 12)
                    }

                    // FAA bar
                    if probe.depth.isCalibrated && probe.depth.faa != 0 {
                        FAABarView(faa: probe.depth.faa)
                            .padding(.horizontal, 44)
                            .padding(.top, 8)
                    }

                    // Band chart — inside scroll so it's reachable on any iPhone size
                    if probe.depth.isCalibrated && !probe.bandHistory.isEmpty {
                        BandChart(history: probe.bandHistory)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom controls
            HStack(spacing: 0) {
                BottomButton(
                    icon: "timer",
                    label: sessionTimer.isRunning ? sessionTimer.formattedRemaining : "Timer",
                    active: sessionTimer.isRunning
                ) { showTimer = true }

                Divider().frame(height: 28).background(.white.opacity(0.1))

                BottomButton(
                    icon: "waveform",
                    label: sound.activeLayers.isEmpty
                        ? "Sounds"
                        : "\(sound.activeLayers.count) active",
                    active: !sound.activeLayers.isEmpty
                ) { showSoundscape = true }

                Divider().frame(height: 28).background(.white.opacity(0.1))

                BottomButton(
                    icon: "stop.circle",
                    label: "End",
                    active: false
                ) { showEndConfirm = true }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.04))
            .confirmationDialog("End this session?", isPresented: $showEndConfirm,
                                titleVisibility: .visible) {
                Button("End Session", role: .destructive) { probe.manualEndSession() }
                Button("Cancel", role: .cancel) { }
            }
        }
        // D3: "Session saved" toast — driven by probe.sessionSavedToast (set in endSessionGracefully).
        .toast(message: $toastMessage)
        .onChange(of: probe.sessionSavedToast) { _, newVal in
            if let msg = newVal {
                withAnimation { toastMessage = msg }
                probe.sessionSavedToast = nil  // reset so next save can fire again
            }
        }
    }
}

// MARK: - Depth gauge

private struct DepthGaugeView: View {
    @ObservedObject var probe: Probe
    @State private var pulse = false

    // B77: display = personal ECDF rank of current z. Replaces (sigmoid_score - 0.5) * 2.
    // Uses the EMA-smoothed ECDF computed in DepthGate so the gauge needle is
    // consistent with the gate's enter/exit logic (both operate on smoothedDisplay).
    private var displayScore: Float { probe.gate.smoothedDisplay }
    private var isCalibrated: Bool { probe.depth.isCalibrated }
    private var inDeep: Bool { probe.gate.inDeepState }
    // Gate threshold in display space — same domain as displayScore now (no remapping).
    // All state labels/colors are fractions of gdt so they adapt with personalization.
    private var gdt: Float { max(0.01, probe.gate.enterThresholdEcdf) }

    private var gaugeColor: Color {
        if !isCalibrated { return .white.opacity(0.2) }
        if inDeep { return Color(red: 0.20, green: 0.95, blue: 0.60) }
        if displayScore > 0.75 * gdt { return Color(red: 0.20, green: 0.80, blue: 0.90) }
        if displayScore > 0.35 * gdt { return Color(red: 0.95, green: 0.75, blue: 0.20) }
        return Color(red: 0.50, green: 0.50, blue: 0.55)
    }

    private var stateText: String {
        if !isCalibrated {
            let s = Int((1.0 - Double(probe.depth.calibrationProgress)) * DepthScore.calibrationDuration)
            return "Calibrating… \(s)s"
        }
        if inDeep { return "Deep state" }
        if displayScore > 0.80 * gdt { return "Approaching depth" }
        if displayScore > 0.50 * gdt { return "Deepening…" }
        if displayScore > 0.15 * gdt { return "Settling…" }
        return "Find your breath"
    }

    private var trainingHint: String {
        if !isCalibrated { return "Keep the headband still" }
        if inDeep { return "Remain… effortless awareness" }
        if displayScore > 0.75 * gdt { return "Let go of the breath — just observe" }
        if displayScore > 0.35 * gdt { return "Soften attention… anchor gently" }
        return "Notice thoughts, return to breath"
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 14)
                    .frame(width: 240, height: 240)

                // Progress arc
                Circle()
                    .trim(from: 0,
                          to: isCalibrated ? CGFloat(displayScore) : CGFloat(probe.depth.calibrationProgress))
                    .stroke(gaugeColor,
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 240, height: 240)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: displayScore)
                    .scaleEffect(inDeep && pulse ? 1.03 : 1.0)
                    .animation(
                        inDeep ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true) : .default,
                        value: pulse)

                // Center content
                VStack(spacing: 4) {
                    if isCalibrated {
                        Text("\(Int(displayScore * 100))")
                            .font(.system(size: 64, weight: .thin, design: .rounded))
                            .foregroundStyle(gaugeColor)
                            .monospacedDigit()
                            .animation(.easeInOut(duration: 0.4), value: displayScore)
                        Text("depth")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.30))
                    } else {
                        ProgressView()
                            .tint(gaugeColor)
                            .scaleEffect(1.4)
                    }
                }
            }
            .onAppear { pulse = true }

            // State label
            Text(stateText)
                .font(.title3.weight(.medium))
                .foregroundStyle(inDeep ? gaugeColor : .white.opacity(0.75))
                .animation(.easeInOut(duration: 0.5), value: inDeep)

            Text(trainingHint)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - FAA bar

private struct FAABarView: View {
    let faa: Float  // typically -1 to +1

    private var clamped: Float { max(-1.0, min(1.0, faa * 3.0)) }

    var body: some View {
        VStack(spacing: 4) {
            Text("Frontal Alpha Asymmetry")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.30))
            GeometryReader { geo in
                let w = geo.size.width
                let mid = w / 2
                let x = mid + CGFloat(clamped) * mid / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08)).frame(height: 4)
                    // Center tick
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(width: 1, height: 10)
                        .offset(x: mid - 0.5, y: -3)
                    // Indicator dot
                    Circle()
                        .fill(clamped >= 0
                              ? Color(red: 0.30, green: 0.90, blue: 0.50)
                              : Color(red: 0.95, green: 0.55, blue: 0.20))
                        .frame(width: 10, height: 10)
                        .offset(x: x - 5, y: -3)
                        .animation(.easeInOut(duration: 0.5), value: clamped)
                }
            }
            .frame(height: 10)
            HStack {
                Text("withdrawal")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.22))
                Spacer()
                Text("approach")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.22))
            }
        }
    }
}

// MARK: - B77: Live SDK Elements diagnostic strip

private struct ElementsStripView: View {
    @ObservedObject var probe: Probe
    @ObservedObject var elements = ElementsTracker.shared

    private func chip(_ label: String, _ value: Float, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.30))
            Text(value.isFinite ? String(format: "%.2f", value) : "—")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(color.opacity(value.isFinite ? 0.85 : 0.25))
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        let v = elements.values
        HStack(spacing: 4) {
            chip("α_rel", v.alphaRelative, Color(red: 0.30, green: 0.85, blue: 0.55))
            chip("θ_rel", v.thetaRelative, Color(red: 0.30, green: 0.65, blue: 0.95))
            chip("β_rel", v.betaRelative,  Color(red: 0.95, green: 0.55, blue: 0.20))
            chip("α_sdk", v.alphaScore,    Color(red: 0.30, green: 0.85, blue: 0.55))
            chip("θ_sdk", v.thetaScore,    Color(red: 0.30, green: 0.65, blue: 0.95))
            chip("β_sdk", v.betaScore,     Color(red: 0.95, green: 0.55, blue: 0.20))
            if let r = probe.rmssd {
                chip("RMSSD", r, .white)
            }
        }
    }
}

// MARK: - B77: Subjective tap-to-mark row

private struct MarksRowView: View {
    @ObservedObject var probe: Probe
    @State private var lastTapped: MarkType? = nil

    private func tap(_ type: MarkType) {
        let t = Date().timeIntervalSince(probe.recordingStartedAtForUI ?? Date())
        let display = probe.gate.smoothedDisplay
        let z: Float? = probe.depth.isCalibrated ? probe.depth.z : nil
        let mark = Mark(time: t, type: type, displayScore: display, depthZ: z)
        probe.marks.add(time: t, type: type, display: display, z: z)
        SessionRecorder.shared.addMark(mark)
        lastTapped = type
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if lastTapped == type { lastTapped = nil }
        }
    }

    private func btn(_ label: String, _ symbol: String, _ type: MarkType, _ color: Color) -> some View {
        Button { tap(type) } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(label).font(.caption2.weight(.medium))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(color.opacity(lastTapped == type ? 0.40 : 0.12))
            .clipShape(Capsule())
            .foregroundStyle(color.opacity(0.90))
            .scaleEffect(lastTapped == type ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.2), value: lastTapped)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            btn("Deepest",    "arrow.down.circle", .deepest,
                Color(red: 0.20, green: 0.85, blue: 0.55))
            btn("Transition", "arrow.left.and.right.circle", .transition,
                Color(red: 0.85, green: 0.75, blue: 0.20))
            btn("Shallowest", "arrow.up.circle", .shallowest,
                Color(red: 0.95, green: 0.55, blue: 0.30))
        }
    }
}

// MARK: - Signal chips

// MARK: - Pre-session fit-stability banner (B83)

/// Shown during calibration when contact has not been continuously good for 5 s.
/// Each second of stable allGood ticks the counter; any contact flip resets it.
/// Communicates to the user: "your band needs to settle before calibration can finish."
private struct FitStabilityBannerView: View {
    let consecutiveGood: Int
    let fit: FitCheckSnapshot

    private var badChannelLabels: [String] {
        var b: [String] = []
        if !fit.tp9  { b.append("TP9")  }
        if !fit.af7  { b.append("AF7")  }
        if !fit.af8  { b.append("AF8")  }
        if !fit.tp10 { b.append("TP10") }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .font(.system(size: 14, weight: .semibold))
                Text(badChannelLabels.isEmpty
                     ? "Hold steady — locking fit \(consecutiveGood)/5 s"
                     : "Reseat band — \(badChannelLabels.joined(separator: ", ")) loose")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))

            // 5-segment progress bar.
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < consecutiveGood
                              ? Color.green.opacity(0.8)
                              : Color.white.opacity(0.18))
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct SignalChipsView: View {
    let fit: FitCheckSnapshot
    let hsi: [Double]
    /// B83 — UI-stable HSI tier per channel (4-of-5 sliding majority on rounded value).
    /// Replaces direct `hsi` reads to suppress single-sample yellow/green flicker.
    /// Indexing: [0]=TP9, [1]=AF7, [2]=AF8, [3]=TP10. Empty = no HSI yet.
    let hsiStable: [Int]
    /// B83 — render counter sink. Increments on body invocation so SessionRecorder.appendUIState
    /// can prove the chip view is rendering.
    @ObservedObject var probe: Probe

    private func hsiLabel(_ i: Int) -> (String, Color) {
        // B83 — prefer stable tier when available; fall back to raw only if buffer empty.
        if hsiStable.count > i {
            switch hsiStable[i] {
            case 1:  return ("●", .green)
            case 2:  return ("●", .orange)
            default: return ("●", .red)
            }
        }
        guard hsi.count > i else { return ("●", .gray) }
        switch hsi[i] {
        case ..<2.0: return ("●", .green)
        case ..<3.5: return ("●", .orange)
        default:     return ("●", .red)
        }
    }

    var body: some View {
        // B83 — increment render counter via task modifier (post-body, no state-during-update warning).
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                let (sym, col) = hsiLabel(i)
                Text(sym).font(.system(size: 10)).foregroundStyle(col)
            }
        }
        .task(id: hsiStable) {
            probe.chipViewRendered += 1
        }
    }
}

// MARK: - Bottom button

private struct BottomButton: View {
    let icon:   String
    let label:  String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(active ? .white : .white.opacity(0.40))
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? .white.opacity(0.85) : .white.opacity(0.35))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @ObservedObject var probe: Probe
    @ObservedObject private var sound = SoundscapePlayer.shared
    @ObservedObject private var sessionTimer = SessionTimer.shared   // D1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Headband") {
                    LabeledContent("State",   value: probe.connection)
                    LabeledContent("Battery", value: "\(Int(probe.battery))%")
                    LabeledContent("Heart Rate", value: probe.heartRate > 0 ? "\(Int(probe.heartRate.rounded())) bpm" : "—")
                    FitDot("TP9",  on: probe.fit.tp9)
                    FitDot("AF7",  on: probe.fit.af7)
                    FitDot("AF8",  on: probe.fit.af8)
                    FitDot("TP10", on: probe.fit.tp10)
                    SignalQualityView(hsi: probe.hsiRaw, packets: probe.packetCount)
                }
                Section("Band Powers (log10 µV²)") {
                    LabeledContent("Windows", value: "\(probe.bandUpdateCount)")
                    LabeledContent("α Alpha",  value: String(format: "%.3f", probe.frontAlpha))
                    LabeledContent("θ Theta",  value: String(format: "%.3f", probe.frontTheta))
                    LabeledContent("β Beta",   value: String(format: "%.3f", probe.frontBeta))
                    LabeledContent("FAA",      value: String(format: "%.3f", probe.depth.faa))
                }
                Section("Depth") {
                    if probe.depth.isCalibrated {
                        LabeledContent("Score (sigmoid)",    value: String(format: "%.2f", probe.depth.score))
                        LabeledContent("z-score",            value: String(format: "%.2f", probe.depth.z))
                        LabeledContent("idx (raw)",          value: String(format: "%.3f", probe.depth.meditationIndex))
                        LabeledContent("idx (corrected)",    value: String(format: "%.3f", probe.depth.meditationIndexCorrected))
                        LabeledContent("Display (ECDF)",     value: String(format: "%.0f%%", probe.gate.smoothedDisplay * 100))
                        LabeledContent("State",              value: probe.gate.inDeepState ? "Deep" : "Shallow")
                        let zd = PersonalZDistribution.shared
                        LabeledContent("Personal z range",
                                       value: String(format: "[%.2f, %.2f]", zd.p5, zd.p95))
                        LabeledContent("Sessions in dist.",
                                       value: "\(zd.sessionCount) (\(zd.trackName))")
                        if zd.sessionCount == 0 {
                            Text("Cold-start: gauge uses within-session percentile rank (rolling 5min window) until first session is saved. Personal cross-session LUT activates at session 2.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if probe.scorer.calibrationIndexMean != 0 {
                            LabeledContent("Cal. Baseline Mean",
                                           value: String(format: "%.3f", probe.scorer.calibrationIndexMean))
                            LabeledContent("Cal. Baseline Std",
                                           value: String(format: "%.3f", probe.scorer.calibrationIndexStd))
                            Text("Std < 0.10: unusually stable or artifacted. Std > 0.35: high variability — recalibrate.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        let calSecs = Int(DepthScore.calibrationDuration)
                        LabeledContent("Calibrating…",
                                       value: "\(Int(Double(probe.depth.calibrationProgress) * DepthScore.calibrationDuration))s / \(calSecs)s")
                    }
                }
                Section("Biomarkers") {
                    LabeledContent("1/f Slope (χ)",
                                   value: probe.aperiodicSlope.map { String(format: "%.2f", $0) } ?? "—")
                    LabeledContent("θ Peak (iTPF)",
                                   value: probe.iTPFFrontal.map { String(format: "%.2f Hz", $0) } ?? "—")
                    LabeledContent("RMSSD",
                                   value: probe.rmssd.map { String(format: "%.0f ms", $0) } ?? "— (needs 5 min)")
                    LabeledContent("LF/HF Ratio",
                                   value: probe.lfhfRatio.map { String(format: "%.2f", $0) } ?? "—")
                    if let r = probe.rmssd, r > 90 {
                        Text("RMSSD > 90 ms is high — verify Optics signal quality during deep states. If contact dots are red/orange while deep, the BPM detection may be miscounting.")
                            .font(.caption).foregroundStyle(.orange.opacity(0.8))
                    }
                }
                // B77: SDK Muse Elements — cross-validation against our pipeline.
                Section("SDK Elements (Muse-validated)") {
                    let v = probe.elements.values
                    LabeledContent("α absolute", value: v.alphaAbsolute.isFinite ? String(format: "%.3f", v.alphaAbsolute) : "—")
                    LabeledContent("θ absolute", value: v.thetaAbsolute.isFinite ? String(format: "%.3f", v.thetaAbsolute) : "—")
                    LabeledContent("β absolute", value: v.betaAbsolute.isFinite  ? String(format: "%.3f", v.betaAbsolute)  : "—")
                    LabeledContent("α relative", value: v.alphaRelative.isFinite ? String(format: "%.3f", v.alphaRelative) : "—")
                    LabeledContent("θ relative", value: v.thetaRelative.isFinite ? String(format: "%.3f", v.thetaRelative) : "—")
                    LabeledContent("β relative", value: v.betaRelative.isFinite  ? String(format: "%.3f", v.betaRelative)  : "—")
                    LabeledContent("α score (SDK)", value: v.alphaScore.isFinite ? String(format: "%.2f", v.alphaScore) : "—")
                    LabeledContent("θ score (SDK)", value: v.thetaScore.isFinite ? String(format: "%.2f", v.thetaScore) : "—")
                    LabeledContent("β score (SDK)", value: v.betaScore.isFinite  ? String(format: "%.2f", v.betaScore)  : "—")
                    if let muse = v.museStyleDepth {
                        LabeledContent("Muse-style depth", value: String(format: "%.2f", muse))
                    }
                    Text("SDK session scores use Interaxon's Elements algorithm: linear p10→p90 mapping over recent rolling history. Cross-check against our personal-ECDF gauge. Large divergence indicates pipeline bug.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Chimes — preview") {
                    HStack(spacing: 10) {
                        Image(systemName: "bell")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(ChimeEngine.shared.chimeVolume) },
                            set: { ChimeEngine.shared.chimeVolume = Float($0) }
                        ), in: 0...1)
                        Image(systemName: "bell.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ChimePreviewRow(label: "Enter Deep",     detail: "432 Hz",          color: .green)  { ChimeEngine.shared.playEnterDeep() }
                    ChimePreviewRow(label: "Going Deeper",   detail: "528 Hz · +0.08 ECDF / 30s", color: .mint)   { ChimeEngine.shared.playDeepening() }
                    ChimePreviewRow(label: "Exit Deep",      detail: "288 Hz",          color: .cyan)   { ChimeEngine.shared.playExitDeep() }
                    ChimePreviewRow(label: "Anchor Tone",    detail: "7 Hz θ binaural", color: .indigo) { ChimeEngine.shared.playConditioningAnchor() }
                    ChimePreviewRow(label: "β Wander",       detail: "1 kHz tick",      color: .yellow) { ChimeEngine.shared.playBetaCue() }
                    ChimePreviewRow(label: "Contact Lost",   detail: "660 Hz ping",     color: .orange) { ChimeEngine.shared.playContactLost() }
                    ChimePreviewRow(label: "Restored",       detail: "528→660 Hz",      color: .mint)   { ChimeEngine.shared.playContactRestored() }
                    ChimePreviewRow(label: "Timer End",      detail: "84 Hz × 3",       color: .purple) { ChimeEngine.shared.playTimerEnd() }
                }
                Section("Training") {
                    LabeledContent("Binaural Fade Level") {
                        Text(String(format: "%.0f%%", sound.binauralFadeLevel * 100))
                            .foregroundStyle(sound.binauralFadeLevel < 0.5 ? .orange : .primary)
                    }
                    LabeledContent("Sessions (qualifying)", value: "\(sound.successfulSessionCount)")
                    Text("Fade decreases 5% per qualifying session (≥5 min recorded, ≥1 deep episode) after 3+ sessions. Trains independence from audio entrainment. Binaural stays functional at any level — turn it off manually when ready.")
                        .font(.caption).foregroundStyle(.secondary)
                    if sound.binauralFadeLevel < 1.0 {
                        Button("Reset Fade to 100%") { sound.resetBinauralFade() }
                            .foregroundStyle(.orange)
                    }
                    let savedEnter = UserDefaults.standard.float(forKey: "adaptiveEnterEcdf")
                    LabeledContent("Adaptive Deep Threshold (ECDF)",
                                   value: savedEnter >= 0.50
                                       ? String(format: "%.0f%%", savedEnter * 100)
                                       : String(format: "Default %.0f%%", probe.gate.enterThresholdEcdf * 100))
                    Text("Gate fires when ECDF display crosses this percentile of your personal history. B77+: defaults to top 30% (0.70). Personalizes to 75th-pct of session mean displays after 5+ sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset Personal ECDF to Bootstrap") {
                        PersonalZDistribution.shared.resetToBootstrap()
                    }
                    .foregroundStyle(.orange)
                    Text("Wipes B77+ session distribution; restores B76 bootstrap LUT. Use only if personalization has gone bad.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Aperiodic Correction (FOOOF)", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "aperiodicCorrectionEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "aperiodicCorrectionEnabled") }
                    ))
                    Text("Donoghue 2020: subtracts 1/f aperiodic component from band power before scoring. Cleaner oscillatory signal but may shift z distribution. Disable if first B77 session saturates and try again — modern ECDF activates at 3 sessions to renormalize.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("β Wander Alert", isOn: Binding(
                        get: { probe.betaCueEnabled },
                        set: { probe.betaCueEnabled = $0 }
                    ))
                    Text("Brief 1 kHz tick when frontal beta spikes >1.5 SD during shallow state. Trains metacognitive awareness of mind-wandering.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // D1: Session length auto-timer. Starts at calibration complete, ends session on expiry.
                Section("Session length") {
                    Picker("Duration", selection: $sessionTimer.selectedDurationMin) {
                        ForEach(SessionTimer.allowedDurations, id: \.self) { min in
                            Text("\(min) min").tag(min)
                        }
                    }
                    .pickerStyle(.segmented)
                    if sessionTimer.isRunning {
                        let r = sessionTimer.remainingSec
                        let m = r / 60, s = r % 60
                        LabeledContent("Remaining", value: String(format: "%d:%02d", m, s))
                            .foregroundStyle(.green)
                    }
                    Text("Auto-starts at calibration complete. Plays gong and saves session at end.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Recording") {
                    // D5: onSaveStop routes through endSessionGracefully (gong + toast + fade).
                    RecordingControlView(onSaveStop: { probe.manualEndSession() })
                }
                Section("Past Sessions") {
                    SessionsListView()
                }
                Section("Spotify") {
                    SpotifyRow()
                }
                if #available(iOS 15.0, *) {
                    Section("Diagnostics") {
                        NavigationLink("View Logs") {
                            DiagnosticsView()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Soundscape sheet

private struct SoundscapeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var spotify = SpotifyManager.shared

    var body: some View {
        NavigationStack {
            List {
                if spotify.isConnected {
                    Section("Spotify") {
                        if !spotify.currentTrack.isEmpty {
                            Text(spotify.currentTrack)
                                .font(.subheadline)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            spotify.isPaused ? spotify.play() : spotify.pause()
                        } label: {
                            Label(spotify.isPaused ? "Play" : "Pause",
                                  systemImage: spotify.isPaused ? "play.fill" : "pause.fill")
                        }
                    }
                }
                SoundscapeLayerView()
            }
            .navigationTitle("Soundscapes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Timer sheet

private struct TimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sessionTimer = SessionTimer.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Session Duration") {
                    Picker("Duration", selection: $sessionTimer.selectedDurationMin) {
                        ForEach(SessionTimer.allowedDurations, id: \.self) { min in
                            Text("\(min) min").tag(min)
                        }
                    }
                    .pickerStyle(.wheel)
                    .disabled(sessionTimer.isRunning)
                    if sessionTimer.isRunning {
                        Text("Change takes effect on next session")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if sessionTimer.isRunning {
                    Section("Running") {
                        LabeledContent("Remaining", value: sessionTimer.formattedRemaining)
                            .monospacedDigit()
                        LabeledContent("Total", value: "\(sessionTimer.selectedDurationMin) min")
                    }
                }
                Section {
                    Text("Timer starts automatically when calibration completes. Session ends and data is saved when it expires.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Session Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct SoundscapeLayerView: View {
    @ObservedObject private var sound = SoundscapePlayer.shared

    var body: some View {
        ForEach(SoundLayer.allCases) { layer in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(layer.rawValue, systemImage: layer.icon)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { sound.activeLayers.contains(layer) },
                        set: { _ in sound.toggle(layer) }
                    ))
                    .labelsHidden()
                }
                if sound.activeLayers.contains(layer) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(sound.layerVolumes[layer] ?? 0.35) },
                            set: { sound.setVolume(Float($0), for: layer) }
                        ), in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if layer == .binaural {
                        Picker("Beat", selection: $sound.binauralPreset) {
                            ForEach(BinauralPreset.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Use headphones for binaural effect")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SpotifyRow: View {
    @ObservedObject private var spotify = SpotifyManager.shared

    var body: some View {
        if spotify.isConnected {
            LabeledContent("Status", value: "Connected")
            if !spotify.currentTrack.isEmpty {
                LabeledContent("Track", value: spotify.currentTrack)
            }
            Button(spotify.isPaused ? "Resume" : "Pause") {
                spotify.isPaused ? spotify.play() : spotify.pause()
            }
            Button("Disconnect", role: .destructive) { spotify.disconnect() }
        } else {
            Button("Connect Spotify") { spotify.authorize() }
                .foregroundStyle(.green)
            Text("Start a playlist in Spotify first, then tap Connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Signal quality

private struct SignalQualityView: View {
    let hsi:     [Double]
    let packets: Int

    private let channels = ["TP9", "AF7", "AF8", "TP10"]

    var body: some View {
        if hsi.count >= 4 {
            ForEach(0..<4, id: \.self) { i in
                LabeledContent(channels[i]) {
                    Text(label(hsi[i]))
                        .foregroundStyle(color(hsi[i]))
                        .fontWeight(.medium)
                }
            }
        } else {
            Text("Waiting for signal…").foregroundStyle(.secondary)
        }
        LabeledContent("Packets received", value: packets.formatted())
            .foregroundStyle(.secondary)
            .font(.caption)
    }

    private func label(_ v: Double) -> String {
        switch v {
        case ..<1.5: "Excellent"
        case ..<2.0: "Good"
        case ..<2.5: "Mediocre"
        case ..<3.5: "Poor"
        default:     "No contact"
        }
    }

    private func color(_ v: Double) -> Color {
        switch v {
        case ..<2.0: .green   // matches allGood threshold
        case ..<3.5: .orange
        default:     .red
        }
    }
}

private struct FitDot: View {
    let label: String
    let on: Bool
    init(_ label: String, on: Bool) { self.label = label; self.on = on }
    var body: some View {
        Label(label, systemImage: on ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(on ? .green : .secondary)
    }
}

// MARK: - Chime preview row

private struct ChimePreviewRow: View {
    let label:  String
    let detail: String
    let color:  Color
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(label, action: action).foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MeditationTimer removed in B87 — unified into SessionTimer.

// MARK: - Recording control

private struct RecordingControlView: View {
    @ObservedObject private var rec = SessionRecorder.shared
    /// D3: onSaveStop routes through Probe.endSessionGracefully for gong + toast.
    var onSaveStop: (() -> Void)? = nil

    var body: some View {
        if rec.isRecording {
            Label("Recording in progress", systemImage: "circle.fill")
                .foregroundStyle(.red)
            // B80(D): Save & Stop routes through endSessionGracefully (gong + toast + soundscape fade).
            Button("Save & Stop") {
                if let handler = onSaveStop {
                    handler()
                } else {
                    // Fallback: direct endSession with reason for diagnostics.
                    _ = rec.endSession(reason: "manual-ui-fallback")
                }
            }
            .foregroundStyle(.orange)
        } else {
            Button("Start Manual Recording") { rec.startSession() }
                .foregroundStyle(.blue)
        }
        Text("Auto-starts when calibration completes · first 300s tagged as warmup · saved to Files → MusePlus → MuseSessions")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Sessions list

private struct SessionsListView: View {
    @ObservedObject private var rec = SessionRecorder.shared

    var body: some View {
        if rec.savedSessions.isEmpty {
            Text("No sessions recorded yet.").foregroundStyle(.secondary)
        } else {
            ForEach(rec.savedSessions, id: \.path) { url in
                HStack {
                    Text(url.deletingPathExtension().lastPathComponent
                            .replacingOccurrences(of: "session_", with: "")
                            .replacingOccurrences(of: "_", with: "  "))
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    ShareLink(item: url,
                              preview: SharePreview(url.lastPathComponent,
                                                    image: Image(systemName: "doc.text"))) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .onDelete { idxs in
                idxs.forEach { rec.deleteSession(at: rec.savedSessions[$0]) }
            }
        }
    }
}

// MARK: - Session summary sheet

private struct SessionSummarySheet: View {
    let record: SessionRecord
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("This Session") {
                    LabeledContent("Duration",   value: fmtMins(record.durationMinutes))
                    LabeledContent("Deep Time",  value: fmtMins(record.deepMinutes))
                    if let latency = record.episodes.first?.enterTime {
                        let avg = UserDefaults.standard.double(forKey: "avgInductionLatency")
                        HStack {
                            Text("First Deep")
                            Spacer()
                            Text(fmtSecs(latency))
                                .foregroundStyle(avg > 0 ? (latency < avg ? .green : .secondary) : .secondary)
                            if avg > 0 {
                                let pct = Int(((avg - latency) / avg * 100).rounded())
                                if abs(pct) >= 10 {
                                    Text(pct > 0 ? "+\(pct)%" : "\(pct)%")
                                        .font(.caption2)
                                        .foregroundStyle(pct > 0 ? .green : .orange)
                                }
                            }
                        }
                    }
                    if let longest = record.episodes.compactMap(\.duration).max() {
                        LabeledContent("Longest Deep", value: fmtMins(longest / 60))
                    }
                    LabeledContent("Deep Episodes", value: "\(record.episodes.count)")
                }
                if chiMean != nil || itpfMean != nil || rmssdMean != nil {
                    Section("Biomarkers") {
                        if let chi = chiMean {
                            LabeledContent("Mean χ (1/f slope)", value: String(format: "%.2f", chi))
                        }
                        if let itpf = itpfMean {
                            LabeledContent("θ Peak (iTPF)", value: String(format: "%.1f Hz", itpf))
                        }
                        if let rmssd = rmssdMean {
                            LabeledContent("RMSSD", value: String(format: "%.0f ms", rmssd))
                        }
                        if let lfhf = lfhfMean {
                            LabeledContent("LF/HF Ratio", value: String(format: "%.2f", lfhf))
                        }
                    }
                }
                let streak = UserDefaults.standard.integer(forKey: "meditationStreak")
                if streak > 0 {
                    Section("Practice") {
                        LabeledContent("Streak", value: "\(streak) day\(streak == 1 ? "" : "s")")
                    }
                }
                // B77: subjective marks agreement. <70% triggers recalibration suggestion.
                if let marks = record.marks, !marks.isEmpty {
                    let scores = record.samples.compactMap(\.ecdfDisplay)
                    let agreement = MarkAgreement.compute(marks: marks, sessionScores: scores)
                    Section("Marks Agreement") {
                        LabeledContent("Marks logged", value: "\(marks.count)")
                        if agreement.deepestCount > 0 {
                            LabeledContent("Deepest in top-25%",
                                           value: "\(agreement.deepestInTop25)/\(agreement.deepestCount)")
                        }
                        if agreement.shallowestCount > 0 {
                            LabeledContent("Shallowest in bottom-25%",
                                           value: "\(agreement.shallowestInBottom25)/\(agreement.shallowestCount)")
                        }
                        let pct = Int((agreement.agreementPct * 100).rounded())
                        LabeledContent("Agreement", value: "\(pct)%")
                            .foregroundStyle(pct >= 70 ? .green : .orange)
                        if pct < 70 {
                            Text("Gauge disagrees with subjective experience on >30% of marks. Consider resetting the personal ECDF (Settings → Training) and recalibrating with a longer eyes-closed pre-meditation period.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section("Insight") {
                    Text(coachingLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Session Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private var chiMean: Float? {
        let v = record.samples.compactMap(\.aperiodicSlopeMean)
        return v.isEmpty ? nil : v.reduce(0, +) / Float(v.count)
    }

    private var itpfMean: Float? {
        let v = record.samples.compactMap(\.iTPFFrontal)
        return v.isEmpty ? nil : v.reduce(0, +) / Float(v.count)
    }

    private var rmssdMean: Float? {
        let v = record.samples.compactMap(\.rmssd)
        return v.isEmpty ? nil : v.reduce(0, +) / Float(v.count)
    }

    private var lfhfMean: Float? {
        let v = record.samples.compactMap(\.lfhfRatio)
        return v.isEmpty ? nil : v.reduce(0, +) / Float(v.count)
    }

    private var coachingLine: String {
        let deep         = record.deepMinutes
        let latency      = record.episodes.first?.enterTime ?? 9999
        let longest      = record.episodes.compactMap(\.duration).max() ?? 0
        let episodeCount = record.episodes.count
        let avgLatency   = UserDefaults.standard.double(forKey: "avgInductionLatency")

        if record.episodes.isEmpty {
            return "No confirmed deep state. Soften jaw, eyes, and shoulders — the gate opens through release, not effort."
        }

        // Chi leads when strong — it's the only signal independent of the calibration baseline
        if let chi = chiMean, chi < -1.5 {
            return "Aperiodic slope χ = \(String(format: "%.2f", chi)) — neural evidence of genuine absorption, independent of the depth score. The signature is real."
        }

        // Cross-session latency comparison: only shown when meaningful (≥20% difference, ≥3 historical sessions)
        if avgLatency > 0, latency < 9999 {
            let improvePct = (avgLatency - latency) / avgLatency * 100
            if improvePct >= 20 {
                return "Induction \(Int(improvePct.rounded()))% faster than your average (\(fmtSecs(avgLatency))). The pathway is consolidating — this is the adaptation you're training for."
            } else if improvePct <= -25 {
                return "Slower entry today (\(fmtSecs(latency)) vs avg \(fmtSecs(avgLatency))). Normal variation. Fatigue, stress, and environment all affect induction. One session doesn't erase the trend."
            }
        }

        // Both fast entry AND sustained depth in the same session is the rarest combination
        if latency < 180 && longest > 600 {
            return "Fast entry (\(fmtSecs(latency))) and \(fmtMins(longest / 60)) sustained. Both metrics in the same session — this is exactly the target state."
        }

        if episodeCount >= 3 {
            return "\(episodeCount) deep entries this session. Multiple entries means the state is becoming repeatable, not a single occurrence."
        }

        if latency < 180 {
            return "Entry in \(fmtSecs(latency)) — faster induction is the most trainable parameter. This pathway shortens every time you use it."
        }

        if longest > 600 {
            return "\(fmtMins(longest / 60)) continuous deep state. Retention is the hardest skill. Most practitioners improve induction years before retention. You're ahead of that curve."
        }

        if deep > 5 {
            return "\(fmtMins(deep)) deep across \(episodeCount) episode\(episodeCount == 1 ? "" : "s"). Frequency builds the pattern. Consistency matters more than duration."
        }

        return "Deep state confirmed. Neural encoding begins from the first episode. Consistency from here determines whether this transfers to eyes-open, unaided practice."
    }

    private func fmtMins(_ m: Double) -> String {
        let mins = Int(m); let secs = Int((m - Double(mins)) * 60)
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }

    private func fmtSecs(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }
}
