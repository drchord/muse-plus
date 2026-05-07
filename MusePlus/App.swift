import SwiftUI
import Combine
import UIKit

@main
struct MusePlusApp: App {
    @StateObject private var probe = Probe()

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
    private var sessionStart = Date()
    private var reconnectAttempts = 0
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
        client.discoveredMuses
            .map { $0.compactMap { $0.getName() } }
            .receive(on: RunLoop.main)
            .assign(to: &$muses)

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
                    UIApplication.shared.isIdleTimerDisabled = true
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
                case .disconnected:
                    UIApplication.shared.isIdleTimerDisabled = false
                    self?.calibrationFiredRecording = false
                    self?.recordingStartWork?.cancel()
                    self?.recordingStartWork = nil
                    self?.recordingStartedAt = nil
                    let recUrl = SessionRecorder.shared.endSession()
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
                self.gate.contactsGood = snap.allGood
                // Gate contact chimes behind calibration: during 60s settle-in the headband
                // frequently fluctuates between good/bad contact. Chiming before calibration
                // completes is noisy and unhelpful — user can see contact state via dots.
                guard self.depth.isCalibrated else { return }
                // Post-calibration: record fit events for data, never play contact audio.
                // Dots give visual state — audio mid-sit breaks concentration regardless
                // of which contacts fluctuate (TP9/TP10 are rarely simultaneously green).
                if wasGood && !snap.allGood { SessionRecorder.shared.addFitEvent() }
            }
            .store(in: &bag)

        client.battery
            .receive(on: RunLoop.main)
            .assign(to: &$battery)

        client.eegPacket
            .receive(on: RunLoop.main)
            .sink { [weak self] pkt in
                guard let self else { return }
                self.lastEEG = pkt.channels
                self.packetCount += 1
                self.pipeline.process(pkt)
            }
            .store(in: &bag)

        client.hsiRaw
            .receive(on: RunLoop.main)
            .sink { [weak self] vals in
                self?.hsiCount += 1
                self?.hsiRaw = vals
            }
            .store(in: &bag)

        pipeline.onBandPowers = { [weak self] powers, correctedPowers in
            guard let self else { return }
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
            if self.depth.isCalibrated && self.betaCueEnabled {
                let bm = self.scorer.calibrationBetaMean
                let bs = self.scorer.calibrationBetaStd
                if bs > 0, self.frontBeta > bm + 1.5 * bs, self.depth.score < 0.3 {
                    let now = Date()
                    if now.timeIntervalSince(self.lastBetaCueDate) >= 30.0 {
                        self.lastBetaCueDate = now
                        ChimeEngine.shared.playBetaCue()
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
                phase:         phase
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
                SessionRecorder.shared.startSession(
                    calibrationIndexMean: self.scorer.calibrationIndexMean,
                    calibrationIndexStd:  self.scorer.calibrationIndexStd
                )
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

        client.startScan()
    }

    // UserDefaults-backed toggle: default true. No @Published needed — Settings reads inline.
    var betaCueEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "betaCueEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "betaCueEnabled") }
    }

    // Manual session end from UI — stops recording, fades soundscape, shows summary.
    // Does NOT disconnect the headband; visual feedback continues.
    func manualEndSession() {
        SoundscapePlayer.shared.stopAll(fadeSeconds: 2.0)
        recordingStartWork?.cancel()
        let recUrl = SessionRecorder.shared.endSession()
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
                return
            }
        }
        // Recording hadn't started (ended before 300s grace period) — show empty summary
        // so user gets sheet confirmation rather than a silent no-op after tapping End.
        let now = Date()
        sessionSummary = SessionRecord(id: UUID().uuidString, startDate: now, endDate: now,
                                       samples: [], episodes: [], fitEvents: [])
    }

    func connectFirst() {
        if let m = IXNMuseManagerIos.sharedManager().getMuses().first {
            client.connect(to: m)
            scorer.startCalibration()
            gate.reset()
            // B77: restore ECDF-space adaptive thresholds. Old "adaptiveDeepThreshold" key
            // stored sigmoid-space value; ignored after migration. New keys:
            // adaptiveEnterEcdf / adaptiveExitEcdf in [0.50, 0.85] / [0.40, 0.75].
            let savedEnter = UserDefaults.standard.float(forKey: "adaptiveEnterEcdf")
            let savedExit  = UserDefaults.standard.float(forKey: "adaptiveExitEcdf")
            if savedEnter >= 0.50 && savedExit >= 0.40 {
                gate.setEcdfThresholds(enter: savedEnter, exit: savedExit)
            } else {
                gate.setEcdfThresholds(enter: 0.70, exit: 0.50)  // defaults
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.connection == "Disconnected" else {
                self?.reconnectAttempts = 0
                return
            }
            self.reconnect()
        }
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
        .onAppear { SessionRecorder.shared.loadSavedSessions() }
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
                        Button(action: { probe.connectFirst() }) {
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                Text(name)
                                    .fontWeight(.medium)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 28)
            }
            Spacer()
        }
    }
}

// MARK: - Meditation main view

private struct MeditationView: View {
    @ObservedObject var probe: Probe
    @Binding var showSettings:   Bool
    @Binding var showSoundscape: Bool
    @Binding var showTimer:      Bool

    @State private var showEndConfirm = false
    @ObservedObject private var timer = MeditationTimer.shared
    @ObservedObject private var sound = SoundscapePlayer.shared

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
                SignalChipsView(fit: probe.fit, hsi: probe.hsiRaw)
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

            Spacer(minLength: 0)

            // Hero depth gauge
            DepthGaugeView(probe: probe)

            Spacer(minLength: 8)

            // B77: subjective tap-to-mark — user is the only ground truth. Marks compared
            // against gauge in session summary; <70% agreement triggers recalibration prompt.
            if probe.depth.isCalibrated && SessionRecorder.shared.isRecording {
                MarksRowView(probe: probe)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 6)
            }

            // FAA bar (after calibration)
            if probe.depth.isCalibrated && probe.depth.faa != 0 {
                FAABarView(faa: probe.depth.faa)
                    .padding(.horizontal, 44)
                    .padding(.bottom, 8)
            }

            // Band chart (only when calibrated and data available)
            if probe.depth.isCalibrated && !probe.bandHistory.isEmpty {
                BandChart(history: probe.bandHistory)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Spacer(minLength: 0)

            // Bottom controls
            HStack(spacing: 0) {
                BottomButton(
                    icon: "timer",
                    label: timer.isRunning ? timer.formattedRemaining : "Timer",
                    active: timer.isRunning
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

private struct SignalChipsView: View {
    let fit: FitCheckSnapshot
    let hsi: [Double]

    private func hsiLabel(_ i: Int) -> (String, Color) {
        guard hsi.count > i else { return ("●", .gray) }
        // HSI SDK values: 1=good, 2=mediocre, 4=no contact.
        // Threshold aligns with FitCheckSnapshot.allGood (< 2.0) so green dot = genuinely good.
        // Removes yellow: HSI=2 (headband partially off or nearby) now shows orange, not yellow.
        switch hsi[i] {
        case ..<2.0: return ("●", .green)   // good contact
        case ..<3.5: return ("●", .orange)  // mediocre — not ideally seated or off skin
        default:     return ("●", .red)     // no contact (HSI=4)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                let (sym, col) = hsiLabel(i)
                Text(sym).font(.system(size: 10)).foregroundStyle(col)
            }
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
        }
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @ObservedObject var probe: Probe
    @ObservedObject private var sound = SoundscapePlayer.shared
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
                Section("Recording") {
                    RecordingControlView()
                }
                Section("Past Sessions") {
                    SessionsListView()
                }
                Section("Spotify") {
                    SpotifyRow()
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
    var body: some View {
        NavigationStack {
            List { SoundscapeLayerView() }
                .navigationTitle("Soundscapes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Timer sheet

private struct TimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List { MeditationTimerView() }
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

// MARK: - Meditation timer model

final class MeditationTimer: ObservableObject {
    static let shared = MeditationTimer()

    @Published var duration:  TimeInterval = 20 * 60
    @Published var remaining: TimeInterval = 0
    @Published var isRunning  = false
    @Published var isDone     = false

    private var endDate:      Date?
    private var displayTimer: Timer?

    func start() {
        isDone    = false
        isRunning = true
        endDate   = Date().addingTimeInterval(duration)
        remaining = duration
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        isRunning    = false
        isDone       = false
        remaining    = 0
    }

    var formattedRemaining: String {
        let r = max(0, remaining)
        let h = Int(r) / 3600
        let m = (Int(r) % 3600) / 60
        let s = Int(r) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func tick() {
        guard let end = endDate else { return }
        let r = max(0, end.timeIntervalSinceNow)
        remaining = r
        if r <= 0 {
            displayTimer?.invalidate()
            displayTimer = nil
            isRunning    = false
            isDone       = true
            ChimeEngine.shared.playTimerEnd()
            // Fade soundscape out as timer ends — session is complete
            SoundscapePlayer.shared.stopAll(fadeSeconds: 4.0)
        }
    }
}

// MARK: - Meditation timer view

private struct MeditationTimerView: View {
    @ObservedObject private var mt = MeditationTimer.shared

    private let presets: [(String, TimeInterval)] = [
        ("5 min",  300),  ("10 min", 600),  ("15 min", 900),
        ("20 min", 1200), ("30 min", 1800), ("45 min", 2700),
        ("60 min", 3600), ("90 min", 5400),
    ]

    var body: some View {
        Picker("Duration", selection: $mt.duration) {
            ForEach(presets, id: \.1) { label, secs in
                Text(label).tag(secs)
            }
        }
        .pickerStyle(.menu)
        .disabled(mt.isRunning)

        if mt.isRunning || mt.isDone {
            LabeledContent(mt.isDone ? "Session complete" : "Remaining",
                           value: mt.isDone ? "" : mt.formattedRemaining)
                .foregroundStyle(mt.isDone ? .green : .primary)
        }

        Button(mt.isRunning ? "Stop" : "Start") {
            mt.isRunning ? mt.stop() : mt.start()
        }
        .foregroundStyle(mt.isRunning ? .red : .green)
    }
}

// MARK: - Recording control

private struct RecordingControlView: View {
    @ObservedObject private var rec = SessionRecorder.shared

    var body: some View {
        if rec.isRecording {
            Label("Recording in progress", systemImage: "circle.fill")
                .foregroundStyle(.red)
            Button("Save & Stop") { rec.endSession() }
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
