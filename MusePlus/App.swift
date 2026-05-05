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
    @Published var depth: DepthResult = DepthResult(score: 0.5, isCalibrated: false, calibrationProgress: 0, faa: 0)
    @Published var bandUpdateCount: Int = 0
    @Published var bandHistory: [BandSample] = []
    @Published var heartRate: Double = 0
    @Published var aperiodicSlope: Float? = nil  // IRASA mean χ; nil when R² quality gate fails
    @Published var iTPFFrontal: Float?    = nil  // frontal theta peak Hz; nil until reliable

    let client   = MuseClient()
    let pipeline = EEGPipeline()
    let scorer   = DepthScore()
    let gate     = DepthGate()
    private var bag = Set<AnyCancellable>()
    private var sampleIndex = 0
    private var sessionStart = Date()
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
                    self?.sessionStart = Date()
                    self?.sampleIndex  = 0
                    self?.bandHistory  = []
                    SessionRecorder.shared.startSession()
                    self?.reconnectAttempts = 0
                case .disconnected:
                    UIApplication.shared.isIdleTimerDisabled = false
                    SessionRecorder.shared.endSession()
                    self?.pipeline.endSession()
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
                if wasGood && !snap.allGood {
                    ChimeEngine.shared.playContactLost()
                    SessionRecorder.shared.addFitEvent()
                } else if !wasGood && snap.allGood {
                    ChimeEngine.shared.playContactRestored()
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
            self.scorer.process(powers)
            // Record after scorer.process so depth reflects current frame
            SessionRecorder.shared.addSample(
                alpha: self.frontAlpha, theta: self.frontTheta,
                beta:  self.frontBeta,  delta: self.frontDelta,
                gamma: self.frontGamma, depth: self.depth.score,
                inDeep: self.gate.inDeepState,
                heartRateBPM: self.heartRate > 0 ? Float(self.heartRate) : nil,
                faa: self.depth.faa,
                aperiodicSlopeMean: self.aperiodicSlope,
                iTPFFrontal: self.iTPFFrontal
            )
        }

        scorer.onResult = { [weak self] result in
            guard let self else { return }
            self.depth = result
            self.gate.update(result)
            SoundscapePlayer.shared.updateAdaptiveDepth(result.score, iTPF: self.iTPFFrontal)
        }

        pipeline.onAperiodicUpdate = { [weak self] chi in
            DispatchQueue.main.async { self?.aperiodicSlope = chi }
        }

        pipeline.onITPFUpdate = { [weak self] iTPF in
            DispatchQueue.main.async { self?.iTPFFrontal = iTPF }
        }

        client.artifactDetected
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pipeline.suppressArtifact() }
            .store(in: &bag)

        client.heartRate
            .receive(on: RunLoop.main)
            .assign(to: &$heartRate)

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
                ConnectView(probe: probe)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings)   { SettingsSheet(probe: probe) }
        .sheet(isPresented: $showSoundscape) { SoundscapeSheet() }
        .sheet(isPresented: $showTimer)      { TimerSheet() }
        .onAppear { SessionRecorder.shared.loadSavedSessions() }
    }
}

// MARK: - Connect screen

private struct ConnectView: View {
    @ObservedObject var probe: Probe

    var body: some View {
        VStack(spacing: 32) {
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

            Spacer(minLength: 0)

            // Hero depth gauge
            DepthGaugeView(probe: probe)

            Spacer(minLength: 8)

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
                    icon: "checkmark.circle",
                    label: "Check-in",
                    active: false
                ) { ChimeEngine.shared.playCheckIn() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.04))
        }
    }
}

// MARK: - Depth gauge

private struct DepthGaugeView: View {
    @ObservedObject var probe: Probe
    @State private var pulse = false

    private var score: Float { probe.gate.smoothedScore }
    private var isCalibrated: Bool { probe.depth.isCalibrated }
    private var inDeep: Bool { probe.gate.inDeepState }

    private var gaugeColor: Color {
        if !isCalibrated { return .white.opacity(0.2) }
        if inDeep { return Color(red: 0.20, green: 0.95, blue: 0.60) }
        if score > 0.55 { return Color(red: 0.20, green: 0.80, blue: 0.90) }
        if score > 0.35 { return Color(red: 0.95, green: 0.75, blue: 0.20) }
        return Color(red: 0.50, green: 0.50, blue: 0.55)
    }

    private var stateText: String {
        if !isCalibrated {
            let s = Int((1.0 - probe.depth.calibrationProgress) * 60)
            return "Calibrating… \(s)s"
        }
        if inDeep { return "Deep state" }
        if score > 0.65 { return "Approaching depth" }
        if score > 0.50 { return "Deepening…" }
        if score > 0.35 { return "Settling…" }
        return "Find your breath"
    }

    private var trainingHint: String {
        if !isCalibrated { return "Keep the headband still" }
        if inDeep { return "Remain… effortless awareness" }
        if score > 0.55 { return "Let go of the breath — just observe" }
        if score > 0.35 { return "Soften attention… anchor gently" }
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
                          to: isCalibrated ? CGFloat(score) : CGFloat(probe.depth.calibrationProgress))
                    .stroke(gaugeColor,
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 240, height: 240)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: score)
                    .scaleEffect(inDeep && pulse ? 1.03 : 1.0)
                    .animation(
                        inDeep ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true) : .default,
                        value: pulse)

                // Center content
                VStack(spacing: 4) {
                    if isCalibrated {
                        Text("\(Int(score * 100))")
                            .font(.system(size: 64, weight: .thin, design: .rounded))
                            .foregroundStyle(gaugeColor)
                            .monospacedDigit()
                            .animation(.easeInOut(duration: 0.4), value: score)
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

// MARK: - Signal chips

private struct SignalChipsView: View {
    let fit: FitCheckSnapshot
    let hsi: [Double]

    private func hsiLabel(_ i: Int) -> (String, Color) {
        guard hsi.count > i else { return ("?", .gray) }
        switch hsi[i] {
        case ..<1.5: return ("●", .green)
        case ..<2.5: return ("●", .yellow)
        case ..<3.5: return ("●", .orange)
        default:     return ("●", .red)
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
                        LabeledContent("Score",    value: String(format: "%.2f", probe.depth.score))
                        LabeledContent("Smoothed", value: String(format: "%.2f", probe.gate.smoothedScore))
                        LabeledContent("State",    value: probe.gate.inDeepState ? "Deep" : "Shallow")
                    } else {
                        LabeledContent("Calibrating…",
                                       value: "\(Int(probe.depth.calibrationProgress * 60))s / 60s")
                    }
                }
                Section("Biomarkers") {
                    LabeledContent("1/f Slope (χ)",
                                   value: probe.aperiodicSlope.map { String(format: "%.2f", $0) } ?? "—")
                    LabeledContent("θ Peak (iTPF)",
                                   value: probe.iTPFFrontal.map { String(format: "%.2f Hz", $0) } ?? "—")
                }
                Section("Chimes — preview") {
                    ChimePreviewRow(label: "Enter Deep",     detail: "432 Hz",      color: .green)  { ChimeEngine.shared.playEnterDeep() }
                    ChimePreviewRow(label: "Exit Deep",      detail: "288 Hz",      color: .cyan)   { ChimeEngine.shared.playExitDeep() }
                    ChimePreviewRow(label: "Contact Lost",   detail: "660 Hz ping", color: .orange) { ChimeEngine.shared.playContactLost() }
                    ChimePreviewRow(label: "Restored",       detail: "528→660 Hz",  color: .mint)   { ChimeEngine.shared.playContactRestored() }
                    ChimePreviewRow(label: "Timer End",      detail: "84 Hz × 3",   color: .purple) { ChimeEngine.shared.playTimerEnd() }
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
        case ..<2.5: "Good"
        case ..<3.5: "Fair"
        default:     "Poor"
        }
    }

    private func color(_ v: Double) -> Color {
        switch v {
        case ..<2.5: .green
        case ..<3.5: .yellow
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
