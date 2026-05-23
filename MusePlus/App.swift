import SwiftUI
import Combine
import UIKit
import AVFoundation
import OSLog
import BackgroundTasks
import Charts

@main
struct MusePlusApp: App {
    @StateObject private var probe = Probe()

    init() {
        // B80: register BGProcessingTask handler for crash-safe NDJSON flush.
        // Must be called before app finishes launching (before first scene connect).
        SessionRecorder.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            ProbeView(probe: probe)
                .onAppear { probe.start() }
                .onOpenURL { SpotifyManager.shared.handleCallback($0) }
        }
    }
}

// MARK: - Session Forecast

enum SessionForecast {
    case strong, building, slow

    var label: String {
        switch self {
        case .strong:   return "Strong start"
        case .building: return "Building"
        case .slow:     return "Slow start"
        }
    }
    var iconName: String {
        switch self {
        case .strong:   return "arrow.up.circle.fill"
        case .building: return "chart.line.uptrend.xyaxis"
        case .slow:     return "tortoise.fill"
        }
    }
    var color: Color {
        switch self {
        case .strong:   return .green
        case .building: return .orange
        case .slow:     return .secondary
        }
    }
}

// MARK: - Warmup FAA Readiness

enum WarmupFAAReadiness {
    case ready(faa: Float)    // ≤ -0.08: right-frontal dominant → predicts deep session (r=-0.76)
    case neutral(faa: Float)  // (-0.08, 0.02): unsettled
    case caution(faa: Float)  // ≥  0.02: left-frontal arousal → harder session predicted

    init(faa: Float) {
        // Derived from data: warmup FAA ≤-0.10 → deepFraction≥0.85 in 4/4 sessions (n=8, r=-0.76).
        // Using -0.08 as conservative threshold to account for measurement noise at n=8.
        // Positive FAA sessions had mean deepFraction 0.20 in observed data.
        if faa <= -0.08        { self = .ready(faa: faa) }
        else if faa < 0.02     { self = .neutral(faa: faa) }
        else                   { self = .caution(faa: faa) }
    }

    var label: String {
        switch self {
        case .ready:   return "Brain ready"
        case .neutral: return "Settling — 3 slow breaths, release effort"
        case .caution: return "High arousal — 5 × 6s exhales, drop shoulders"
        }
    }
    var iconName: String {
        switch self {
        case .ready:   return "brain"
        case .neutral: return "circle.dotted"
        case .caution: return "exclamationmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .ready:   return .green
        case .neutral: return Color.orange.opacity(0.8)
        case .caution: return .orange
        }
    }
    var faaValue: Float {
        switch self {
        case .ready(let f), .neutral(let f), .caution(let f): return f
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
                                                     calibrationProgress: 0, faa: 0,
                                                     alphaPowerRatio: 0.5)
    // B77: subjective tap-to-mark collector. Cleared on session start.
    @Published var marks = MarkCollector()
    // B77: SDK Elements tracker for cross-validation against our pipeline.
    @ObservedObject var elements = ElementsTracker.shared
    @Published var bandUpdateCount: Int = 0
    @Published var bandHistory: [BandSample] = []
    @Published var heartRate: Double = 0
    // B96: 5-sample rolling buffer for HR artifact rejection.
    // Median of last 5 values; reject incoming if |value - median| > 35 BPM.
    private var heartRateBuffer: [Float] = []
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
    // B107: set at session start from UserDefault; gates raw vs cleaned EEG path for this session.
    // Read-once at calibration completion so the path stays stable for the entire session.
    private var liveDenoiseEnabled = false
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
    // B121: temporal-contact gate. Calibration deferred until TP9 (idx 0) and TP10 (idx 3)
    // stable tier are both ≤ 2 (not-bad). Prevents calibration on Muse S/Athena when ear
    // electrodes are unseated, which biases calibrationIndexMean and mis-seats the headband.
    // Safety: 15s timeout force-starts calibration if hsiPrecision packets never arrive
    // (SDK not emitting, firmware variant) so the session is never permanently blocked.
    @Published var temporalGateBlocked: Bool = false
    private var calibrationPending: Bool = false
    private var temporalGateTimeoutWork: DispatchWorkItem?
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
    @Published var sessionForecast: SessionForecast? = nil
    // B99: warmup FAA readiness + induction-stall alert state
    @Published var warmupFAAReadiness: WarmupFAAReadiness? = nil
    @Published var showInductionStall: Bool = false
    private var warmupFAASamples:    [Float] = []
    private var warmupTransitionFired = false
    private var hasEverEnteredDeep    = false
    private var inductionStallTimer:   DispatchWorkItem? = nil
    // B102: escalating stall coaching at 600s and 900s
    private var inductionStallTimer600: DispatchWorkItem? = nil
    private var inductionStallTimer900: DispatchWorkItem? = nil
    // B102: approach zone tracking — 50–100% of gate threshold, sustained 20s
    private var approachWindowCount   = 0
    private var lastApproachChimeDate = Date.distantPast
    private let approachChimeCooldown: TimeInterval = 120.0
    // B76 had a 300s recording delay after calibration; B77 records from calibration end and
    // tags first 300s as "warmup" instead. No data loss; analysis can still filter warmup.
    private var recordingStartWork: DispatchWorkItem?  // legacy field; kept to avoid wider refactor
    private var calibrationFiredRecording = false
    private var calibrationCompleted = false
    private var recentEcdf: [Float] = []
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
                        SessionRecorder.shared.recordBLEReconnect()  // B107: count successful reconnects
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
                    // B121: gate state reset handled by doConnect(); don't override here.
                    self?.hrv.setCalibrationPhase(true)  // B107-T11: start collecting calibration-phase RR
                    self?.sessionForecast     = nil
                    self?.calibrationCompleted = false
                    self?.recentEcdf           = []
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
                        Telemetry.connection.notice("entering 45s grace period")
                        // Schedule 45s grace expiry
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
                        // B107: record stall for post-session analysis
                        SessionRecorder.shared.recordBLEStall()
                        self?.gracePeriodWork = gracework
                        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: gracework)
                        self?.scheduleReconnect()
                        return
                    }
                    // Not recording (or already in grace period): standard disconnect path.
                    // Stop soundscape (missing before B80 — soundscape kept playing after disconnect).
                    SoundscapePlayer.shared.stopAll(fadeSeconds: 1.0)
                    self?.calibrationFiredRecording = false
                    self?.calibrationPending  = false   // B121: clear gate on disconnect
                    self?.temporalGateBlocked = false
                    self?.temporalGateTimeoutWork?.cancel()
                    self?.temporalGateTimeoutWork = nil
                    self?.recordingStartWork?.cancel()
                    self?.recordingStartWork = nil
                    // B80(D): cancel session-length timer (session is ending here, no grace).
                    SessionTimer.shared.cancel()
                    // B80: stop liveness watchdog, increment disconnect counter, log event.
                    LivenessWatchdog.shared.stop()
                    self?.sessionDiagCounters.disconnectCount += 1
                    self?.recordEvent(kind: "disconnect")
                    // B109: recordingStartedAt moved to AFTER buildDiagnostics (was before; caused sessionMin=0 → fitsPerMin=0).
                    // B109: full HRV attach block added (was missing; dfaAlpha1/enterThreshold never exported on disconnect path).
                    if let s = self {
                        SessionRecorder.shared.attachDiagnostics(
                            s.buildDiagnostics(endReason: "disconnect"))
                        SessionRecorder.shared.attachEventStream(s.sessionEvents)
                        SessionRecorder.shared.attachEnterThreshold(s.gate.enterThresholdEcdf)
                        let hrvScalars = s.hrv.drainLatestHRVScalars()
                        SessionRecorder.shared.attachHRVScalars(sdnn: hrvScalars.sdnn, sd1: hrvScalars.sd1, sd2: hrvScalars.sd2)
                        if let calRmssd = s.hrv.calibrationRmssd {
                            SessionRecorder.shared.attachCalibrationRmssd(calRmssd)
                        }
                        let sessionRR = s.hrv.extractSessionRR()
                        if let alpha = HRVPipeline.computeDFAAlpha1(sessionRR) {
                            SessionRecorder.shared.attachDFAAlpha1(alpha)
                        }
                    }
                    self?.recordingStartedAt = nil
                    Telemetry.recording.error("endSession reason=disconnect")
                    let completedRec = SessionRecorder.shared.endSession(reason: "disconnect")
                    self?.pipeline.endSession()
                    self?.hrv.reset()
                    self?.rmssd     = nil
                    self?.lfhfRatio = nil
                    if let rec = completedRec {
                        self?.sessionSummary = rec
                        if !rec.episodes.isEmpty && rec.durationMinutes >= 5.0 {
                            SoundscapePlayer.shared.decrementBinauralFade(
                                latencyToFirstDeep: rec.episodes.first?.enterTime)
                        }
                        self?.computeSessionAnalytics()
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
                // B107: when live denoiser is active, skip raw path — cleaned-batch
                // subscriber below calls pipeline.processCleanedWindow() instead.
                guard !self.liveDenoiseEnabled else { return }
                self.pipeline.process(pkt)
                // B80: notify liveness watchdog of every raw packet.
                LivenessWatchdog.shared.packetReceived()
            }
            .store(in: &bag)

        // B107: cleaned-batch subscription — active only when eegDenoiseLiveSignal=true.
        // EEGWindowBuffer emits one [[Float]] per second (256-sample window, 4 channels).
        // Feeds processCleanedWindow() which runs the same FFT/band-power/IRASA path as
        // the raw process() call but on the denoiser output.
        EEGWindowBuffer.shared.cleanedBatch
            .receive(on: RunLoop.main)
            .sink { [weak self] channels in
                guard let self, self.liveDenoiseEnabled else { return }
                self.pipeline.processCleanedWindow(channels)
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
                    // B121: unblock calibration when TP9 + TP10 stable tier both ≤ 2 (not-bad).
                    // hsiStableTier requires 4-of-5 HSI packets to agree before flipping (B83 majority
                    // filter, ≤5s latency per B83 comment). One check per packet is sufficient.
                    // NOTE: hsiPrecision rate not confirmed in SDK docs; inferred ~1 Hz from B83 "≤5s".
                    // Bounds-guard: hsiStableTier is always count==4 after doConnect() reset, but
                    // guard defensively in case of future refactors.
                    if self.calibrationPending &&
                       self.hsiStableTier.count == 4 &&
                       self.hsiStableTier[0] <= 2 &&
                       self.hsiStableTier[3] <= 2 {
                        self.calibrationPending  = false
                        self.temporalGateBlocked = false
                        self.scorer.startCalibration()
                        Telemetry.recording.notice("B121 temporal gate cleared: TP9=\(self.hsiStableTier[0], privacy: .public) TP10=\(self.hsiStableTier[3], privacy: .public)")
                        SessionRecorder.shared.appendGateEvent(
                            path: "cleared",
                            tp9Tier: self.hsiStableTier[0],
                            tp10Tier: self.hsiStableTier[3])
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
            // B94: smoothedDisplay is now Kalman-filtered (not EMA). Callers get smoother, faster-converging state.
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
            // B99: accumulate FAA during warmup; emit readiness banner at warmup→main transition
            if let ph = phase {
                let liveFAA = self.depth.faa
                if ph == "warmup" && liveFAA != 0 {
                    self.warmupFAASamples.append(liveFAA)
                } else if ph == "main" && !self.warmupTransitionFired {
                    self.warmupTransitionFired = true
                    let samples = self.warmupFAASamples
                    // ≥30 samples = ~15s of valid frontal FAA — anything less is noise
                    if samples.count >= 30 {
                        let mean = samples.reduce(0, +) / Float(samples.count)
                        let readiness = WarmupFAAReadiness(faa: mean)
                        Telemetry.recording.notice("warmup-FAA mean=\(mean, privacy: .public) n=\(samples.count, privacy: .public) → \(readiness.label, privacy: .public)")
                        // Dispatch to main: recordEvent is not thread-safe (appends to sessionEvents array)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.recordEvent(kind: "warmup-faa-readiness",
                                             detail: String(format: "%.3f_%@", mean, readiness.label))
                            withAnimation(.easeIn(duration: 0.5)) { self.warmupFAAReadiness = readiness }
                            // B102: spoken coaching — primary channel for closed-eye users.
                            let speechText: String
                            switch readiness {
                            case .ready:
                                speechText = "Brain ready. Settle in."
                            case .neutral:
                                speechText = "Brain still settling. Take three slow breaths. Release any effort."
                            case .caution:
                                speechText = "High arousal detected. Five slow exhales, six seconds each. Drop your shoulders completely."
                            }
                            ChimeEngine.shared.speak(speechText)
                            // B117 C5 — log the coach intervention with state at trigger.
                            SessionRecorder.shared.recordCoach(
                                trigger: "warmup-faa-readiness",
                                diagnosis: readiness.label,
                                intervention: "banner+speech",
                                speechText: speechText,
                                snapshot: self.coachSnapshot()
                            )
                            // Extended display for neutral/caution: user needs time to act on guidance.
                            let displayDuration: TimeInterval
                            switch readiness {
                            case .ready:   displayDuration = 10
                            case .neutral: displayDuration = 22
                            case .caution: displayDuration = 22
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) { [weak self] in
                                withAnimation(.easeOut(duration: 0.5)) { self?.warmupFAAReadiness = nil }
                            }
                        }
                    }
                    self.warmupFAASamples = []
                }
            }
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
                heartRateBPM: self.filteredHeartRate(),
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
            let wasDeep = self.gate.inDeepState
            self.gate.update(result)

            // B102: approach zone — ecdfDisplay in [0.5×gdt, gdt), not in deep, sustained 20s.
            // Fires 360 Hz bowl so user knows they are close without disrupting concentration.
            // Cooldown 120s prevents over-firing during prolonged approach-zone hovering.
            if result.isCalibrated && !gate.inDeepState {
                let inApproach = gate.smoothedDisplay >= 0.5 * gate.enterThresholdEcdf
                              && gate.smoothedDisplay <  gate.enterThresholdEcdf
                if inApproach {
                    approachWindowCount += 1
                    if approachWindowCount >= 40,
                       Date().timeIntervalSince(lastApproachChimeDate) >= approachChimeCooldown {
                        lastApproachChimeDate = Date()
                        approachWindowCount = 0
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            ChimeEngine.shared.playApproachZone()
                            self.recordEvent(kind: "approach-zone",
                                             detail: String(format: "ecdf=%.2f", self.gate.smoothedDisplay))
                            // B117 C5
                            SessionRecorder.shared.recordCoach(
                                trigger: "approach-zone",
                                diagnosis: "near-gate",
                                intervention: "approach-bowl",
                                speechText: nil,
                                snapshot: self.coachSnapshot()
                            )
                        }
                    }
                } else {
                    approachWindowCount = 0
                }
            } else {
                approachWindowCount = 0
            }

            SoundscapePlayer.shared.updateAdaptiveDepth(result.score, iTPF: self.iTPFFrontal)
            // B100: dispatch to main — stall work item also runs on main, so this
            // write serializes correctly and avoids a cross-thread race on hasEverEnteredDeep.
            if !wasDeep && self.gate.inDeepState {
                SpotifyManager.shared.onEnterDeep()     // B103: duck to 25% in deep state
                DispatchQueue.main.async { [weak self] in
                    self?.hasEverEnteredDeep = true
                    self?.inductionStallTimer?.cancel()
                    self?.inductionStallTimer600?.cancel()
                    self?.inductionStallTimer900?.cancel()
                    // B117 C5 — log enter-deep coaching point (no chime here; gate-driven entry has its own audio path).
                    if let self {
                        SessionRecorder.shared.recordCoach(
                            trigger: "enter-deep",
                            diagnosis: nil,
                            intervention: "haptic",
                            speechText: nil,
                            snapshot: self.coachSnapshot()
                        )
                    }
                    // B102: single soft haptic 5s after entry — interoceptive registration.
                    // Fires after enter chime has fully decayed; prompts user to consciously
                    // notice the state they are in without disrupting it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        guard let self, self.gate.inDeepState else { return }
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                }
            }
            // B102: exit recovery — 5s after exiting deep, gentle haptic×3 + return nudge chime.
            // The 5s delay lets the exit chime fully decay before new audio fires.
            // Guard checks user is still outside deep state (didn't immediately re-enter).
            if wasDeep && !self.gate.inDeepState {
                SpotifyManager.shared.onExitDeep()      // B103: restore to 60% on exit
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    guard let self,
                          !self.gate.inDeepState,
                          SessionRecorder.shared.isRecording else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        ChimeEngine.shared.playReturnNudge()
                        // B117 C5
                        if let self {
                            SessionRecorder.shared.recordCoach(
                                trigger: "return-nudge",
                                diagnosis: "exited-deep",
                                intervention: "return-bowl+haptic",
                                speechText: nil,
                                snapshot: self.coachSnapshot()
                            )
                        }
                        // Spoken cue after nudge chime and its 3.8s unduck fully complete (5.5s buffer).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
                            let text = "Return gently. Soften your gaze. Let it find you."
                            ChimeEngine.shared.speak(text)
                            // B117 C5
                            if let self {
                                SessionRecorder.shared.recordCoach(
                                    trigger: "exit-deep-speech",
                                    diagnosis: "exited-deep",
                                    intervention: "speech",
                                    speechText: text,
                                    snapshot: self.coachSnapshot()
                                )
                            }
                        }
                    }
                }
            }
            // B94: at deep state entry, set binaural to raw iTPF (after updateAdaptiveDepth which uses iTPF-2.0)
            if !wasDeep && self.gate.inDeepState, let iTPF = self.gate.lastKnownITPF {
                SoundscapePlayer.shared.setAdaptiveBinauralIfActive(hz: Double(iTPF))
            }
            // B94 — ecdf history for early forecast (fires 60s after first calibration)
            if result.isCalibrated {
                self.recentEcdf.append(self.gate.smoothedDisplay)
                if self.recentEcdf.count > 120 { self.recentEcdf.removeFirst() }
                if !self.calibrationCompleted {
                    self.calibrationCompleted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                        guard let self, self.calibrationCompleted,
                              !self.recentEcdf.isEmpty else { return }
                        let slice = self.recentEcdf.suffix(120)
                        let mean = slice.reduce(0, +) / Float(slice.count)
                        withAnimation(.easeIn(duration: 0.4)) {
                            self.sessionForecast = mean > 0.52 ? .strong :
                                                   mean > 0.38 ? .building : .slow
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                            withAnimation(.easeOut(duration: 0.5)) {
                                self?.sessionForecast = nil
                            }
                        }
                    }
                }
            }
            // B77: record from calibration end (no 300s delay). First 300s tagged "warmup"
            // in addSample so analysis can still filter, but data is preserved.
            if result.isCalibrated && !self.calibrationFiredRecording {
                self.calibrationFiredRecording = true
                // B107: adaptive Kalman qD from calibration variance.
                // baselineStd ∈ [0.10, 0.35] → variance ∈ [0.01, 0.12] → qD ∈ [0.0015, 0.018]
                // Factor 0.15 centres the range around default 0.0022 at typical std≈0.13.
                // Clamped to [0.0005, 0.020].
                let adaptiveQD = min(max(self.scorer.calibrationEcdfVariance * 0.15, 0.0005), 0.020)
                self.gate.setQD(adaptiveQD)
                Telemetry.recording.notice("B107 adaptiveQD=\(adaptiveQD, privacy: .public) ecdfVar=\(self.scorer.calibrationEcdfVariance, privacy: .public)")
                self.recordingStartWork?.cancel()
                self.recordingStartedAt = Date()
                self.marks.reset()
                self.heartRateBuffer.removeAll()
                SpotifyManager.shared.sessionStart()    // B103: set 60% volume at calibration end
                // B99: reset warmup FAA tracking and schedule induction-stall alert at 360s
                self.warmupFAASamples = []
                self.warmupTransitionFired = false
                self.hasEverEnteredDeep    = false
                self.inductionStallTimer?.cancel()
                self.inductionStallTimer600?.cancel()
                self.inductionStallTimer900?.cancel()
                self.approachWindowCount   = 0
                self.lastApproachChimeDate = .distantPast
                let stallWork = DispatchWorkItem { [weak self] in
                    // Runs on main (via DispatchQueue.main.asyncAfter below) — no inner dispatch needed.
                    guard let self,
                          SessionRecorder.shared.isRecording,
                          !self.hasEverEnteredDeep,
                          !self.isPausedForReconnect else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    ChimeEngine.shared.playInductionNudge()
                    // B102: spoken coaching fires after nudge chime + its 3s unduck settle.
                    let stall360Text = "Soften your focus. Stop trying to meditate."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                        ChimeEngine.shared.speak(stall360Text)
                    }
                    self.recordEvent(kind: "induction-stall", detail: "360s-no-deep")
                    Telemetry.recording.notice("induction-stall alert fired at 360s")
                    // B117 C5
                    SessionRecorder.shared.recordCoach(
                        trigger: "induction-stall-360",
                        diagnosis: "no-deep",
                        intervention: "chime+speech+haptic",
                        speechText: stall360Text,
                        snapshot: self.coachSnapshot()
                    )
                    withAnimation { self.showInductionStall = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                        withAnimation { self?.showInductionStall = false }
                    }
                }
                self.inductionStallTimer = stallWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 360, execute: stallWork)

                // B102: 600s stall — breath pacer (3×10s cycles at 6 breaths/min).
                // Spoken prompt first, then 3s delay for speech to finish before pacer starts.
                // Rationale: 6 breaths/min maximally increases RMSSD + alpha, both leading
                // indicators of depth entry. Only fires if user never entered deep state.
                let stallWork600 = DispatchWorkItem { [weak self] in
                    guard let self,
                          SessionRecorder.shared.isRecording,
                          !self.hasEverEnteredDeep,
                          !self.isPausedForReconnect else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let stall600Text = "Follow your breath. Breathe in slowly for five seconds, then out for five."
                    ChimeEngine.shared.speak(stall600Text)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        ChimeEngine.shared.playBreathPacer(cycles: 3)
                    }
                    self.recordEvent(kind: "induction-stall", detail: "600s-breath-pacer")
                    Telemetry.recording.notice("induction-stall 600s: breath pacer fired")
                    // B117 C5
                    SessionRecorder.shared.recordCoach(
                        trigger: "induction-stall-600",
                        diagnosis: "no-deep",
                        intervention: "speech+breath-pacer+haptic",
                        speechText: stall600Text,
                        snapshot: self.coachSnapshot()
                    )
                }
                self.inductionStallTimer600 = stallWork600
                DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: stallWork600)

                // B102: 900s stall — release-effort cue. By 15 minutes with no deep entry
                // the user is likely gripping. Spoken instruction targets the most common
                // block: effortful trying. Nudge chime follows speech.
                let stallWork900 = DispatchWorkItem { [weak self] in
                    guard let self,
                          SessionRecorder.shared.isRecording,
                          !self.hasEverEnteredDeep,
                          !self.isPausedForReconnect else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let stall900Text = "Let go of trying. You are already here. Just rest."
                    ChimeEngine.shared.speak(stall900Text)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                        ChimeEngine.shared.playInductionNudge()
                    }
                    self.recordEvent(kind: "induction-stall", detail: "900s-no-deep")
                    Telemetry.recording.notice("induction-stall 900s fired")
                    // B117 C5
                    SessionRecorder.shared.recordCoach(
                        trigger: "induction-stall-900",
                        diagnosis: "no-deep",
                        intervention: "speech+chime+haptic",
                        speechText: stall900Text,
                        snapshot: self.coachSnapshot()
                    )
                }
                self.inductionStallTimer900 = stallWork900
                DispatchQueue.main.asyncAfter(deadline: .now() + 900, execute: stallWork900)

                ElementsTracker.shared.reset()
                PersonalZDistribution.shared.resetSessionRing()
                // B107: latch live-denoiser flag once per session at calibration end.
                // Reading UserDefault here (not at app launch) so the user can toggle
                // the flag between sessions without restarting the app.
                self.liveDenoiseEnabled = UserDefaults.standard.bool(forKey: "eegDenoiseLiveSignal")
                // B117 F3: force-finalize calibration baseline NOW so calibrationBetaMean/Std
                // hold real values instead of DepthScore defaults (0.0 / 0.30). Without this,
                // the attach below was writing defaults when the first post-warmup sample
                // hadn't yet triggered finalizeBaseline() — root cause of B109 betaZScore=0.
                self.scorer.forceFinalize()
                SessionRecorder.shared.startSession(
                    calibrationIndexMean: self.scorer.calibrationIndexMean,
                    calibrationIndexStd:  self.scorer.calibrationIndexStd
                )
                // B109: attachCalibrationBeta moved to AFTER startSession so isRecording=true
                // when the guard fires. Previously called before startSession → guard blocked it
                // → calibrationBetaMean always nil → betaZScore always 0.
                let _calBetaMean = self.scorer.calibrationBetaMean
                let _calBetaStd  = self.scorer.calibrationBetaStd
                SessionRecorder.shared.attachCalibrationBeta(mean: _calBetaMean, std: _calBetaStd)
                Telemetry.recording.notice("B109 calBeta mean=\(String(describing: _calBetaMean), privacy: .public) std=\(String(describing: _calBetaStd), privacy: .public)")
                // B117 F3: emit calibrationSummary NDJSON record with real values.
                // Analysis tools key off this to verify calibration actually ran with samples.
                SessionRecorder.shared.attachCalibrationSummary(
                    indexMean:   self.scorer.calibrationIndexMean,
                    indexStd:    self.scorer.calibrationIndexStd,
                    betaMean:    _calBetaMean,
                    betaStd:     _calBetaStd,
                    sampleCount: self.scorer.calibrationSampleCount,
                    durationSec: Date().timeIntervalSince(self.sessionStart)
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
            DispatchQueue.main.async {
                self?.iTPFFrontal = iTPF
                self?.gate.lastKnownITPF = iTPF
            }
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

    /// B117: Absolute HR bounds reject counter. Incremented when raw BPM is outside [35,120].
    var hrSamplesRejected: Int = 0

    /// B117 C5: Build a snapshot of current EEG/HRV state for the coach record.
    /// Called at every coaching trigger so post-hoc analysis can correlate intervention to physiology.
    /// Reads the most-recent published Probe values; any unavailable field becomes nil.
    func coachSnapshot() -> CoachStateSnapshot {
        CoachStateSnapshot(
            ecdfDisplay: self.gate.smoothedDisplay,
            beta:        self.frontBeta != 0 ? self.frontBeta : nil,
            alpha:       self.frontAlpha != 0 ? self.frontAlpha : nil,
            theta:       self.frontTheta != 0 ? self.frontTheta : nil,
            faa:         self.depth.faa != 0 ? self.depth.faa : nil,
            heartRateBPM: self.filteredHeartRate()
        )
    }

    /// B96: Rolling-median HR filter. Rejects values where |bpm - median5| > 35.
    /// Physiologically impossible values (30, 192 BPM seen in session data) are sensor artifacts.
    /// B117: Added absolute bounds gate [35, 120] before buffer append.
    private func filteredHeartRate() -> Float? {
        guard heartRate > 0 else { return nil }
        let raw = Float(heartRate)
        guard raw >= 35, raw <= 120 else {
            hrSamplesRejected += 1
            return nil
        }
        heartRateBuffer.append(raw)
        if heartRateBuffer.count > 5 { heartRateBuffer.removeFirst() }
        guard heartRateBuffer.count >= 3 else { return raw }   // not enough history yet
        let sorted = heartRateBuffer.sorted()
        let median = sorted[sorted.count / 2]
        return abs(raw - median) <= 35 ? raw : nil
    }

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
        SpotifyManager.shared.sessionEnd()               // B103: restore full volume
        inductionStallTimer?.cancel()    // B99: kill stall alert if session ends before 360s
        inductionStallTimer = nil
        inductionStallTimer600?.cancel() // B102
        inductionStallTimer600 = nil
        inductionStallTimer900?.cancel() // B102
        inductionStallTimer900 = nil
        // B83 — capture audio state at gong time. The MOST important snapshot for
        // debugging audibility; without this we can't tell whether the speaker had
        // output enabled when the gong fired.
        fireDiagnosticsSnapshot(trigger: "endSession-pre-gong")
        // Fade soundscape FIRST — stopAll sets isStopping=true so AVAudioEngineConfigurationChange
        // from gong's configureAudioSession cannot resurrect looping nodes via resumeActiveLayers.
        // B94: shorten fade to 2s; delay gong 1.5s so it fires into near-silence (soundscape ≈25%).
        // Root cause of buzzing: async stopAll + immediate gong → full-volume overlap → DAC clip.
        SoundscapePlayer.shared.stopAll(fadeSeconds: 2.0)
        // B96: configure AVAudioSession NOW (synchronously) so the category change fires before
        // the soundscape fade is in progress. Previously inside asyncAfter — the category change
        // at t=1.5s could trigger AVAudioEngineConfigurationChange mid-fade causing audio glitch.
        EndGongPlayer.shared.prepareAudioSession()
        // B83 — record session-end event NOW (before endSession closes the NDJSON file).
        recordEvent(kind: "session-end-success", detail: effectiveReason)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Guard: skip gong if a new session started in the 1.5s window.
            guard !SessionRecorder.shared.isRecording else { return }
            // B83 — route to EndGongPlayer. Plays bowl_success.wav; falls back to ChimeEngine.playGong().
            EndGongPlayer.shared.playSuccess()
        }
        MainThreadStall.shared.stop()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        recordingStartWork?.cancel()
        // B80(C): attach diagnostics before endSession so they're included in the saved file.
        SessionRecorder.shared.attachDiagnostics(buildDiagnostics(endReason: effectiveReason))
        SessionRecorder.shared.attachEventStream(sessionEvents)
        SessionRecorder.shared.attachEnterThreshold(gate.enterThresholdEcdf)
        // B107: atomically drain HRV scalars from HRV queue (C2: avoids inconsistent triple)
        let hrvScalars = hrv.drainLatestHRVScalars()
        SessionRecorder.shared.attachHRVScalars(sdnn: hrvScalars.sdnn, sd1: hrvScalars.sd1, sd2: hrvScalars.sd2)
        // B107 C4: calibrationRmssd = first valid RMSSD window (~5 min) as session HRV baseline
        if let calRmssd = hrv.calibrationRmssd {
            SessionRecorder.shared.attachCalibrationRmssd(calRmssd)
        }
        // B107: DFA α1 from full-session RR
        let sessionRR = hrv.extractSessionRR()
        if let alpha = HRVPipeline.computeDFAAlpha1(sessionRR) {
            SessionRecorder.shared.attachDFAAlpha1(alpha)
        }
        Telemetry.recording.notice("endSession reason=\(effectiveReason, privacy: .public)")
        // B98: endSession() returns the completed SessionRecord directly — eliminates the
        // prior file-decode path (try? dec.decode silently returned nil, showing Duration:0s).
        let completedRec = SessionRecorder.shared.endSession(reason: effectiveReason)
        pipeline.endSession()
        hrv.reset()
        rmssd     = nil
        lfhfRatio = nil
        if let rec = completedRec {
            sessionSummary = rec
            sessionSavedToast = "Session saved"
            if !rec.episodes.isEmpty && rec.durationMinutes >= 5.0 {
                SoundscapePlayer.shared.decrementBinauralFade(
                    latencyToFirstDeep: rec.episodes.first?.enterTime)
            }
            computeSessionAnalytics()
            return
        }
        // endSession() returned nil — session may already have ended or closure return was dropped.
        // Attempt disk recovery from the most recently saved session file before showing zeros.
        Telemetry.recording.error("endSessionGracefully: endSession returned nil (reason=\(effectiveReason)) — attempting disk recovery")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("MuseSessions")
        let dec  = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let latestURL = candidates.first,
           let data = try? Data(contentsOf: latestURL),
           let recovered = try? dec.decode(SessionRecord.self, from: data) {
            Telemetry.recording.notice("endSessionGracefully: disk recovery OK from \(latestURL.lastPathComponent, privacy: .public)")
            sessionSummary = recovered
            sessionSavedToast = "Session saved"
            computeSessionAnalytics()
            return
        }
        Telemetry.recording.error("endSessionGracefully: disk recovery failed — showing toast only")
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
        // B121: reset ONLY TP9/TP10 (indices 0, 3) so stale data doesn't mask new contacts.
        // AF7/AF8 (indices 1, 2) are left intact — no reason to show frontal contacts as red
        // when the gate only concerns temporal electrodes.
        hsiBuffer[0] = []; hsiBuffer[3] = []
        if hsiStableTier.count == 4 { hsiStableTier[0] = 4; hsiStableTier[3] = 4 }
        // B121: defer startCalibration() until TP9 + TP10 stable tier ≤ 2.
        // startCalibration() fires from the HSI sink once the gate clears.
        calibrationPending   = true
        temporalGateBlocked  = true
        Telemetry.recording.notice("B121 temporal gate active — awaiting TP9/TP10 tier ≤ 2")
        // B121: 15s safety timeout — if hsiPrecision never arrives (SDK variant, Muse S firmware),
        // force-start calibration so the session is never permanently blocked by the gate.
        temporalGateTimeoutWork?.cancel()
        let gateTimeout = DispatchWorkItem { [weak self] in
            guard let self, self.calibrationPending else { return }
            self.calibrationPending  = false
            self.temporalGateBlocked = false
            self.scorer.startCalibration()
            Telemetry.recording.notice("B121 temporal gate timeout (15s) — force-starting calibration")
            let tp9  = self.hsiStableTier.count > 0 ? self.hsiStableTier[0] : -1
            let tp10 = self.hsiStableTier.count > 3 ? self.hsiStableTier[3] : -1
            SessionRecorder.shared.appendGateEvent(path: "timeout", tp9Tier: tp9, tp10Tier: tp10)
        }
        temporalGateTimeoutWork = gateTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: gateTimeout)
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
            var betaHistory:  [Double]   = []   // B100: rolling beta for trend display

            for url in allUrls.prefix(30) {
                guard let data = try? Data(contentsOf: url),
                      let rec = try? dec.decode(SessionRecord.self, from: data),
                      !rec.episodes.isEmpty else { continue }
                sessionMeans.append(rec.meanDepth)
                if let lat = rec.episodes.first?.enterTime { latencies.append(lat) }
                if let b = rec.mainBetaMean { betaHistory.append(Double(b)) }
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
                // B100: store beta history for trend display in SessionSummarySheet.
                // Stored newest-first (matching allUrls sort order). Sheet reads this,
                // drops current session (index 0), compares current beta vs the rest.
                if !betaHistory.isEmpty {
                    UserDefaults.standard.set(betaHistory, forKey: "betaPowerHistory")
                }
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

    // B80/B107: Called when the 45s grace period expires without reconnect.
    // Tears down session state cleanly, preserves whatever was recorded.
    private func performFinalDisconnect(gracePeriodStart: Date?) {
        calibrationFiredRecording = false
        recordingStartWork?.cancel()
        recordingStartWork = nil
        // B83 — capture audio state at failure-gong time.
        fireDiagnosticsSnapshot(trigger: "performFinalDisconnect-pre-gong")
        // B83 — was missing in B80; grace-expiry would silently end with NO audio cue.
        // EndGongPlayer.playFailure tries `bowl_failure.{m4a,wav}` then falls back to
        // ChimeEngine.playFailureChime (5 short alert pings, all in passband).
        // B119 — long sessions (≥15 min) that end by disconnect get the success gong
        // rather than alert pings; a sustained meditation deserves a gentle close.
        let sessionElapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if sessionElapsed >= 900 {
            EndGongPlayer.shared.playSuccess()
        } else {
            EndGongPlayer.shared.playFailure()
        }
        recordEvent(kind: "session-end-failure", detail: "grace-expired")
        // Lengthen the soundscape fade so it doesn't get cut off mid-gong.
        SoundscapePlayer.shared.stopAll(fadeSeconds: 4.0)
        MainThreadStall.shared.stop()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        // B109: diagnostics block added (was missing entirely); recordingStartedAt moved to after
        // buildDiagnostics so sessionMin is computed correctly before it is cleared.
        SessionRecorder.shared.attachDiagnostics(buildDiagnostics(endReason: "grace-expired"))
        SessionRecorder.shared.attachEventStream(sessionEvents)
        SessionRecorder.shared.attachEnterThreshold(gate.enterThresholdEcdf)
        let hrvScalars = hrv.drainLatestHRVScalars()
        SessionRecorder.shared.attachHRVScalars(sdnn: hrvScalars.sdnn, sd1: hrvScalars.sd1, sd2: hrvScalars.sd2)
        if let calRmssd = hrv.calibrationRmssd {
            SessionRecorder.shared.attachCalibrationRmssd(calRmssd)
        }
        let sessionRR = hrv.extractSessionRR()
        if let alpha = HRVPipeline.computeDFAAlpha1(sessionRR) {
            SessionRecorder.shared.attachDFAAlpha1(alpha)
        }
        recordingStartedAt = nil
        Telemetry.recording.error("endSession reason=grace-expired")
        let completedRec = SessionRecorder.shared.endSession(reason: "grace-expired")
        pipeline.endSession()
        hrv.reset()
        rmssd     = nil
        lfhfRatio = nil
        if let rec = completedRec {
            sessionSummary = rec
            if !rec.episodes.isEmpty && rec.durationMinutes >= 5.0 {
                SoundscapePlayer.shared.decrementBinauralFade(
                    latencyToFirstDeep: rec.episodes.first?.enterTime)
            }
            computeSessionAnalytics()
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
            buildTag:            SessionRecorder.currentBuildTag,
            deviceModel:         model,
            iosVersion:          iosVer,
            museModel:           client.museModelString,
            contactQualityGrade: grade,
            fitEventsPerMin:     fitsPerMin,
            hrSamplesRejected:   hrSamplesRejected > 0 ? hrSamplesRejected : nil
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
    @ObservedObject private var sound   = SoundscapePlayer.shared
    @ObservedObject private var spotify = SpotifyManager.shared
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
                // B103: Spotify one-tap shortcut. Tap = Connect if unlinked; Play/Pause if linked.
                // Green = connected+playing. Dim green = connected+paused. Gray = not connected.
                Button {
                    if spotify.isConnected {
                        spotify.isPaused ? spotify.play() : spotify.pause()
                    } else {
                        spotify.authorize()
                    }
                } label: {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(
                            spotify.isConnected && !spotify.isPaused
                                ? Color(red: 0.20, green: 0.85, blue: 0.45)
                                : spotify.isConnected
                                    ? Color(red: 0.20, green: 0.85, blue: 0.45).opacity(0.4)
                                    : .white.opacity(0.25)
                        )
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
                    if probe.temporalGateBlocked || (!probe.depth.isCalibrated && probe.consecutiveGoodSeconds < 5) {
                        FitStabilityBannerView(consecutiveGood: probe.consecutiveGoodSeconds,
                                               fit: probe.fit,
                                               gatingCalibration: probe.temporalGateBlocked,
                                               hsiStable: probe.hsiStableTier)
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
        .overlay(alignment: .top) {
            if let forecast = probe.sessionForecast {
                SessionForecastBanner(forecast: forecast)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let readiness = probe.warmupFAAReadiness {
                WarmupFAABannerView(readiness: readiness)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if probe.showInductionStall {
                InductionStallBannerView()
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
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

// MARK: - Warmup FAA Banner

private struct WarmupFAABannerView: View {
    let readiness: WarmupFAAReadiness
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: readiness.iconName)
            Text(readiness.label)
            Text(String(format: "FAA %.2f", readiness.faaValue))
                .font(.caption2)
                .opacity(0.7)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(readiness.color)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Induction Stall Banner

private struct InductionStallBannerView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
            Text("Soften your focus")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
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
                    // B122: empirically (n=8) NEGATIVE faa predicts depth (r=-0.76) for Sugato —
                    // inverse of Davidson standard. Green = negative (depth zone), orange = positive
                    // (arousal). Matches WarmupFAAReadiness coloring: faa≤-0.08 → green "Brain ready".
                    Circle()
                        .fill(clamped < 0
                              ? Color(red: 0.30, green: 0.90, blue: 0.50)
                              : Color(red: 0.95, green: 0.55, blue: 0.20))
                        .frame(width: 10, height: 10)
                        .offset(x: x - 5, y: -3)
                        .animation(.easeInOut(duration: 0.5), value: clamped)
                }
            }
            .frame(height: 10)
            HStack {
                Text("depth zone")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.22))
                Spacer()
                Text("arousal")
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
    // B121: when true, banner shows temporal gate UI instead of fit-stability UI.
    var gatingCalibration: Bool = false
    var hsiStable: [Int] = []

    private var badChannelLabels: [String] {
        var b: [String] = []
        if !fit.tp9  { b.append("TP9")  }
        if !fit.af7  { b.append("AF7")  }
        if !fit.af8  { b.append("AF8")  }
        if !fit.tp10 { b.append("TP10") }
        return b
    }

    private func tierColor(_ tier: Int) -> Color {
        switch tier {
        case 1:  return .green
        case 2:  return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .font(.system(size: 14, weight: .semibold))
                if gatingCalibration {
                    Text("Seat TP9 + TP10 to begin")
                        .font(.system(size: 13, weight: .medium))
                } else {
                    Text(badChannelLabels.isEmpty
                         ? "Hold steady — locking fit \(consecutiveGood)/5 s"
                         : "Reseat band — \(badChannelLabels.joined(separator: ", ")) loose")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(.white.opacity(0.9))

            if gatingCalibration {
                // B121: live tier-colored dots for TP9 and TP10.
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(tierColor(hsiStable.count > 0 ? hsiStable[0] : 4))
                            .frame(width: 8, height: 8)
                        Text("TP9")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(tierColor(hsiStable.count > 3 ? hsiStable[3] : 4))
                            .frame(width: 8, height: 8)
                        Text("TP10")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            } else {
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
                    LabeledContent("Chime Volume") {
                        Text(ChimeEngine.shared.chimeVolume == 0
                             ? "0% — drag slider to hear preview"
                             : String(format: "%.0f%%", ChimeEngine.shared.chimeVolume * 100))
                            .foregroundStyle(ChimeEngine.shared.chimeVolume == 0 ? .orange : .secondary)
                            .font(.caption)
                    }
                    ChimePreviewRow(label: "Enter Deep",     detail: "432 Hz",          color: .green)  { ChimeEngine.shared.playEnterDeep() }
                    ChimePreviewRow(label: "Going Deeper",   detail: "528 Hz · +0.08 ECDF / 30s", color: .mint)   { ChimeEngine.shared.playDeepening() }
                    ChimePreviewRow(label: "Exit Deep",      detail: "288 Hz",          color: .cyan)   { ChimeEngine.shared.playExitDeep() }
                    ChimePreviewRow(label: "Anchor Tone",    detail: "7 Hz θ binaural · headphones only", color: .indigo) { ChimeEngine.shared.playConditioningAnchor() }
                    ChimePreviewRow(label: "β Wander",       detail: "1 kHz tick",      color: .yellow) { ChimeEngine.shared.playBetaCue() }
                    ChimePreviewRow(label: "Contact Lost",   detail: "660 Hz ping",     color: .orange) { ChimeEngine.shared.playContactLost() }
                    ChimePreviewRow(label: "Restored",       detail: "528→660 Hz",      color: .mint)   { ChimeEngine.shared.playContactRestored() }
                    ChimePreviewRow(label: "Session End",    detail: "432 Hz bowl",     color: .purple) { EndGongPlayer.shared.playSuccess() }
                    Text("Slider controls all chimes including depth and transition tones. Session-end gong enforces an 85% minimum regardless of this setting — it will always be audible.")
                        .font(.caption).foregroundStyle(.secondary)
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
                Section("Spotify") {
                    if spotify.isConnected {
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
                        Button("Disconnect", role: .destructive) { spotify.disconnect() }
                    } else {
                        Text("Start your T4 playlist in Spotify, then tap Connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Connect Spotify") { spotify.authorize() }
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

private struct DepthPoint: Identifiable {
    let id: Int
    let t: Double   // minutes from session start
    let v: Double   // ecdfDisplay [0, 1]
}

private struct DepthTraceChart: View {
    let points: [DepthPoint]
    let threshold: Double

    var body: some View {
        Chart {
            ForEach(points) { pt in
                LineMark(
                    x: .value("min", pt.t),
                    y: .value("depth", pt.v)
                )
                .foregroundStyle(.blue.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            // Entry threshold
            RuleMark(y: .value("threshold", threshold))
                .foregroundStyle(.orange.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .trailing, alignment: .leading, spacing: 2) {
                    Text("\(Int((threshold * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(.orange)
                }
            // Calibration boundary at 5 min
            RuleMark(x: .value("cal", 5.0))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        .chartYScale(domain: 0.0...1.0)
        .chartXAxisLabel("min", alignment: .trailing)
        .chartYAxisLabel("%")
    }
}

private struct SessionSummarySheet: View {
    let record: SessionRecord
    let onDismiss: () -> Void
    @State private var displayScore: Int = 0
    @State private var showTrends = false

    var body: some View {
        NavigationStack {
            List {
                if let score = record.qualityScore {
                    Section("Session Quality") {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                                Circle()
                                    .trim(from: 0, to: min(1, CGFloat(displayScore) / 100))
                                    .stroke(
                                        score >= 80 ? Color.green : score >= 60 ? Color.orange : Color.red,
                                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(-90))
                                    .animation(.easeOut(duration: 0.8), value: displayScore)
                                Text("\(score)")
                                    .font(.title2.bold())
                            }
                            .frame(width: 68, height: 68)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(score >= 80 ? "Excellent" : score >= 60 ? "Good" : "Building")
                                    .font(.headline)
                                Text("Deep \(Int((record.deepFraction ?? 0) * 100))%  ·  Contact \(Int(frontalGoodPct))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .onAppear {
                            displayScore = score
                        }
                    }
                }

                thisSessionSection
                biomarkersSection
                let streak = UserDefaults.standard.integer(forKey: "meditationStreak")
                if streak > 0 {
                    Section("Practice") {
                        LabeledContent("Streak", value: "\(streak) day\(streak == 1 ? "" : "s")")
                    }
                }
                marksAgreementSection
                if !depthPoints.isEmpty {
                    Section {
                        DepthTraceChart(
                            points: depthPoints,
                            threshold: Double(record.enterThresholdAtSession ?? 0.55)
                        )
                        .frame(height: 150)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } header: {
                        Text("Depth Trace")
                    } footer: {
                        Text("Orange dashed: entry threshold. Vertical grey: end of calibration.")
                            .font(.caption2)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Trends") { showTrends = true }
                }
            }
            .sheet(isPresented: $showTrends) {
                NavigationStack { TrendsView() }
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

    // B96: RMSSD when ecdfDisplay ≥ 0.50 vs < 0.25. Non-nil only when ≥5 samples in each bucket.
    // Positive delta (high > low) = parasympathetic activation tracks with depth signal = system working.
    private var rmssdDepthDelta: (high: Float, low: Float)? {
        let highSamples = record.samples.filter { ($0.ecdfDisplay ?? 0) >= 0.50 }.compactMap(\.rmssd)
        let lowSamples  = record.samples.filter { ($0.ecdfDisplay ?? 1) <  0.25 }.compactMap(\.rmssd)
        guard highSamples.count >= 5, lowSamples.count >= 5 else { return nil }
        let hi = highSamples.reduce(0, +) / Float(highSamples.count)
        let lo = lowSamples.reduce(0, +)  / Float(lowSamples.count)
        return (hi, lo)
    }

    private var lfhfMean: Float? {
        let v = record.samples.compactMap(\.lfhfRatio)
        return v.isEmpty ? nil : v.reduce(0, +) / Float(v.count)
    }

    private var frontalGoodPct: Double {
        let total = record.samples.count
        guard total > 0 else { return 0 }
        return Double(record.samples.filter { $0.frontalGood == true }.count) / Double(total) * 100
    }

    // Downsample to ≤300 points for chart render performance.
    private var depthPoints: [DepthPoint] {
        let all = record.samples.enumerated().compactMap { i, s -> DepthPoint? in
            guard let v = s.ecdfDisplay else { return nil }
            return DepthPoint(id: i, t: s.time / 60.0, v: Double(v))
        }
        guard all.count > 300 else { return all }
        let stride = all.count / 300
        return all.enumerated().compactMap { i, pt in i % stride == 0 ? pt : nil }
    }

    private var coachingLine: String {
        let deep         = record.deepMinutes
        let latency      = record.episodes.first?.enterTime ?? 9999
        let longest      = record.episodes.compactMap(\.duration).max() ?? 0
        let episodeCount = record.episodes.count
        let avgLatency   = UserDefaults.standard.double(forKey: "avgInductionLatency")

        if record.episodes.isEmpty {
            let scores = record.samples.compactMap(\.ecdfDisplay)
            let peak = scores.max() ?? 0
            let thresh = record.enterThresholdAtSession ?? 0.55
            if peak >= thresh * 0.88 {
                let peakPct = Int((peak * 100).rounded())
                let threshPct = Int((thresh * 100).rounded())
                var maxRun = 0; var run = 0
                for s in scores { if s >= thresh { run += 1; maxRun = max(maxRun, run) } else { run = 0 } }
                if peak >= thresh {
                    // Peak exceeded threshold but sustained < 10s — gate never fired
                    let heldSec = maxRun / 2
                    return "Peak depth \(peakPct)% — above the \(threshPct)% threshold for \(heldSec)s (10s needed to confirm). The signal was there. Sustaining it, not chasing it, is the only remaining step."
                }
                // Peak below threshold — near-miss approach
                let gap = Int(((thresh - peak) * 100).rounded())
                if maxRun < 20 {
                    return "Peak depth \(peakPct)% — \(gap) percentile point\(gap == 1 ? "" : "s") from \(threshPct)% threshold. Brief approach, didn't hold. The depth is present — the challenge is sustaining without monitoring."
                }
                return "Peak depth \(peakPct)% — \(gap) percentile point\(gap == 1 ? "" : "s") from the \(threshPct)% threshold. The approach is there. You arrived without crossing. Less monitoring of state, more surrender to the breath."
            }
            // B96: trajectory pattern classifier for no-deep-state sessions.
            let durationMin = record.durationMinutes
            if durationMin > 10 && scores.count > 20 {
                let windowSize = max(1, scores.count / 5)   // 20% of session = one window
                // Segment ECDF into fifths; find peak window index
                let windowPeaks: [Float] = (0..<5).map { w in
                    let slice = Array(scores[(w * windowSize)..<min((w+1) * windowSize, scores.count)])
                    return slice.max() ?? 0
                }
                let peakWindow = windowPeaks.enumerated().max(by: { $0.element < $1.element })?.offset ?? 4
                let mean = scores.reduce(0, +) / Float(scores.count)
                // Two-attempt: a peak in first window AND a peak in last two windows, with valley between
                let earlyPeak = windowPeaks[0..<2].max() ?? 0
                let latePeak  = windowPeaks[3...4].max() ?? 0
                let midValley = windowPeaks[2]
                if earlyPeak >= thresh * 0.70 && latePeak >= thresh * 0.70 && midValley < earlyPeak * 0.70 {
                    let earlyMinStr = fmtMins(Double(windowSize) / 2.0 / 120.0)
                    let lateMinStr  = fmtMins(Double(scores.count - windowSize / 2) / 120.0)
                    return "Two approaches — near the threshold at \(earlyMinStr) and again at \(lateMinStr), with a long middle section below. The capacity showed twice. The challenge is not depth, it is continuity."
                }
                // Flat-low: mean below 20% and max below threshold
                if mean < 0.20 && peak < thresh * 0.70 {
                    let durStr = fmtMins(durationMin)
                    return "Mind stayed active throughout \(durStr). Try a 20-min session tomorrow — shorter duration builds the habit before the length."
                }
                // Late peak only
                if peakWindow >= 3 && earlyPeak < thresh * 0.50 {
                    return "Depth arrived late — the peak came in the final third. The settling took most of the session. This pattern often shortens with consistent practice."
                }
            }
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

    @ViewBuilder private var thisSessionSection: some View {
        Section("This Session") {
            LabeledContent("Duration",   value: fmtMins(record.durationMinutes))
            LabeledContent("Deep Time",  value: fmtMins(record.deepMinutes))
            if let latency = record.episodes.first?.enterTime {
                let avg = UserDefaults.standard.double(forKey: "avgInductionLatency")
                HStack {
                    Text("First Deep")
                    Spacer()
                    Text(fmtSecs(latency))
                        .foregroundStyle(avg > 0 ? (latency < avg ? Color.green : Color.secondary) : Color.secondary)
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
    }

    @ViewBuilder private var biomarkersSection: some View {
        if chiMean != nil || itpfMean != nil || rmssdMean != nil || record.meditationIndexCorrelation != nil || record.mainBetaMean != nil {
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
                if let delta = rmssdDepthDelta {
                    let arrow = delta.high >= delta.low ? "↑" : "↓"
                    LabeledContent("RMSSD high/low depth",
                                   value: String(format: "%.0f / %.0f ms %@", delta.high, delta.low, arrow))
                }
                if let lfhf = lfhfMean {
                    LabeledContent("LF/HF Ratio", value: String(format: "%.2f", lfhf))
                }
                if let r = record.meditationIndexCorrelation {
                    let label = r >= 0.7 ? "strong" : r >= 0.4 ? "moderate" : "weak"
                    LabeledContent("MI/Depth Correlation",
                                   value: String(format: "r = %.2f (%@)", r, label))
                        .foregroundStyle(r >= 0.4 ? Color.primary : Color.orange)
                }
                if let beta = record.mainBetaMean {
                    // Compare to rolling mean of last N sessions (stored by computeSessionAnalytics).
                    // history[0] = current session; compare current vs history[1...].
                    let history = (UserDefaults.standard.array(forKey: "betaPowerHistory") as? [Double]) ?? []
                    let prior = Array(history.dropFirst())
                    if prior.count >= 3 {
                        let mean   = Float(prior.reduce(0, +) / Double(prior.count))
                        let delta  = beta - mean
                        let arrow  = delta < -0.005 ? "↓" : delta > 0.005 ? "↑" : "→"
                        let color: Color = delta < -0.005 ? .green : delta > 0.005 ? .orange : .secondary
                        LabeledContent("β Power (main)",
                                       value: String(format: "%.3f %@ hist %.3f", beta, arrow, mean))
                            .foregroundStyle(color)
                    } else {
                        LabeledContent("β Power (main)", value: String(format: "%.3f (first sessions)", beta))
                    }
                    if let a = record.mainAlphaMean, let t = record.mainThetaMean, t > 0 {
                        LabeledContent("α/θ Ratio", value: String(format: "%.2f", a / t))
                    }
                }
            }
        }
    }

    @ViewBuilder private var marksAgreementSection: some View {
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

private struct SessionForecastBanner: View {
    let forecast: SessionForecast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: forecast.iconName)
                .font(.subheadline)
            Text(forecast.label)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(forecast.color)
        .shadow(radius: 4)
    }
}
