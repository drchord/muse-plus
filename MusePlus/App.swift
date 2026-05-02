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
    @Published var depth: DepthResult = DepthResult(score: 0.5, isCalibrated: false, calibrationProgress: 0)
    @Published var bandUpdateCount: Int = 0
    @Published var bandHistory: [BandSample] = []

    let client   = MuseClient()
    let pipeline = EEGPipeline()
    let scorer   = DepthScore()
    let gate     = DepthGate()
    private var bag = Set<AnyCancellable>()
    private var sampleIndex = 0
    private let sessionStart = Date()
    private var reconnectAttempts = 0

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
                    SessionRecorder.shared.startSession()
                    self?.reconnectAttempts = 0
                case .disconnected:
                    UIApplication.shared.isIdleTimerDisabled = false
                    SessionRecorder.shared.endSession()
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
                // Gong on good→bad; depth chimes suppressed until all green again
                if wasGood && !snap.allGood {
                    ChimeEngine.shared.playContactLost()
                    SessionRecorder.shared.addFitEvent()
                }
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

        pipeline.onBandPowers = { [weak self] powers in
            guard let self else { return }
            let frontal = powers.filter { [1, 2].contains($0.channel) }
            if !frontal.isEmpty {
                let n = Float(frontal.count)
                let alpha = frontal.map(\.alpha).reduce(0, +) / n
                let theta = frontal.map(\.theta).reduce(0, +) / n
                let beta  = frontal.map(\.beta).reduce(0, +)  / n
                let delta = frontal.map(\.delta).reduce(0, +) / n
                let gamma = frontal.map(\.gamma).reduce(0, +) / n
                self.frontAlpha = alpha
                self.frontTheta = theta
                self.frontBeta  = beta
                self.frontDelta = delta
                self.frontGamma = gamma
                self.bandUpdateCount += 1
                let sample = BandSample(
                    id: self.sampleIndex,
                    time: Date().timeIntervalSince(self.sessionStart),
                    alpha: alpha, theta: theta, beta: beta, delta: delta, gamma: gamma
                )
                self.sampleIndex += 1
                self.bandHistory.append(sample)
                if self.bandHistory.count > 120 { self.bandHistory.removeFirst() }
            }
            self.scorer.process(powers)
            // Record after scorer.process so depth reflects current frame
            SessionRecorder.shared.addSample(
                alpha: self.frontAlpha, theta: self.frontTheta,
                beta:  self.frontBeta,  delta: self.frontDelta,
                gamma: self.frontGamma, depth: Float(self.depth.score),
                inDeep: self.gate.inDeepState
            )
        }

        scorer.onResult = { [weak self] result in
            guard let self else { return }
            self.depth = result
            self.gate.update(result)
        }

        client.startScan()
    }

    func connectFirst() {
        if let m = IXNMuseManagerIos.sharedManager().getMuses().first {
            client.connect(to: m)
            scorer.startCalibration()
            gate.reset()
        }
    }

    private func reconnect() {
        // Reconnect without resetting calibration or gate — preserve session continuity
        if let m = IXNMuseManagerIos.sharedManager().getMuses().first {
            client.connect(to: m)
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

// MARK: - ProbeView

struct ProbeView: View {
    @ObservedObject var probe: Probe

    var body: some View {
        NavigationStack {
            List {
                Section("Discovery") {
                    if probe.muses.isEmpty {
                        Text("Scanning…").foregroundStyle(.secondary)
                    } else {
                        ForEach(probe.muses, id: \.self) { name in Text(name) }
                        Button("Connect first") { probe.connectFirst() }
                            .foregroundStyle(.blue)
                    }
                }

                Section("Connection") {
                    LabeledContent("State",   value: probe.connection)
                    LabeledContent("Battery", value: "\(Int(probe.battery))%")
                }

                Section("Fit Check") {
                    FitDot("TP9",  on: probe.fit.tp9)
                    FitDot("AF7",  on: probe.fit.af7)
                    FitDot("AF8",  on: probe.fit.af8)
                    FitDot("TP10", on: probe.fit.tp10)
                }

                Section("EEG") {
                    LabeledContent("Packets", value: "\(probe.packetCount)")
                    if probe.lastEEG.count == 4 {
                        LabeledContent("TP9",  value: String(format: "%.1f", probe.lastEEG[0]))
                        LabeledContent("AF7",  value: String(format: "%.1f", probe.lastEEG[1]))
                        LabeledContent("AF8",  value: String(format: "%.1f", probe.lastEEG[2]))
                        LabeledContent("TP10", value: String(format: "%.1f", probe.lastEEG[3]))
                    }
                }

                Section("Band Powers — last 60 s") {
                    if probe.bandHistory.isEmpty {
                        Text("Waiting for data…").foregroundStyle(.secondary)
                    } else {
                        BandChart(history: probe.bandHistory)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                }

                Section("Band Powers (frontal avg, log10 µV²)") {
                    LabeledContent("Windows", value: "\(probe.bandUpdateCount)")
                    LabeledContent("Alpha 8–13 Hz ↑", value: String(format: "%.3f", probe.frontAlpha))
                    LabeledContent("Theta 4–8 Hz  ↑", value: String(format: "%.3f", probe.frontTheta))
                    LabeledContent("Beta 13–30 Hz ↓", value: String(format: "%.3f", probe.frontBeta))
                }

                Section("Depth Score") {
                    if probe.depth.isCalibrated {
                        LabeledContent("Score", value: String(format: "%.2f", probe.depth.score))
                        ProgressView(value: Double(probe.depth.score))
                            .tint(scoreColor(probe.depth.score))
                        LabeledContent("Smoothed", value: String(format: "%.2f", probe.gate.smoothedScore))
                        LabeledContent("State") {
                            Label(
                                probe.gate.inDeepState ? "Deep" : "Shallow",
                                systemImage: probe.gate.inDeepState ? "bell.fill" : "bell.slash"
                            )
                            .foregroundStyle(probe.gate.inDeepState ? .green : .red)
                            .fontWeight(.semibold)
                        }
                    } else {
                        LabeledContent("Calibrating…",
                                       value: "\(Int(probe.depth.calibrationProgress * 60))s / 60s")
                        ProgressView(value: Double(probe.depth.calibrationProgress))
                    }
                }
                Section("Soundscape") {
                    SoundscapeLayerView()
                }

                Section("Chimes — tap to preview") {
                    ChimePreviewRow(label: "Enter Deep State",
                                   detail: "432 Hz bowl · 3.5 s · fires when depth sustains 20 s",
                                   color: .green) { ChimeEngine.shared.playEnterDeep() }
                    ChimePreviewRow(label: "Exit Deep State",
                                   detail: "528 Hz bowl · 2 s · fires when depth drops for 15 s",
                                   color: .blue) { ChimeEngine.shared.playExitDeep() }
                    ChimePreviewRow(label: "Contact Lost",
                                   detail: "120 Hz gong · 5 s · fires when any electrode loses contact",
                                   color: .orange) { ChimeEngine.shared.playContactLost() }
                    ChimePreviewRow(label: "Timer End",
                                   detail: "80 Hz gong · triple strike · fires when timer reaches zero",
                                   color: .purple) { ChimeEngine.shared.playTimerEnd() }
                }

                Section("Meditation Timer") {
                    MeditationTimerView()
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
            .navigationTitle("Muse++ — Gate 2")
            .onAppear { SessionRecorder.shared.loadSavedSessions() }
        }
    }

    private func scoreColor(_ s: Float) -> Color {
        s > 0.65 ? .green : s > 0.4 ? .yellow : .red
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
        Text("Auto-starts when Muse connects · saved to Files → MusePlus → MuseSessions")
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
