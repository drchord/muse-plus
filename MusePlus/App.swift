import SwiftUI
import Combine

@main
struct MusePlusApp: App {
    @StateObject private var probe = Probe()

    var body: some Scene {
        WindowGroup {
            ProbeView(probe: probe)
                .onAppear { probe.start() }
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
    @Published var frontBeta: Float  = 0
    @Published var depth: DepthResult = DepthResult(score: 0.5, isCalibrated: false, calibrationProgress: 0)
    @Published var bandUpdateCount: Int = 0

    let client   = MuseClient()
    let pipeline = EEGPipeline()
    let scorer   = DepthScore()
    private var bag = Set<AnyCancellable>()

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

        client.fitCheck
            .receive(on: RunLoop.main)
            .assign(to: &$fit)

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
                self.frontAlpha = frontal.map(\.alpha).reduce(0, +) / Float(frontal.count)
                self.frontTheta = frontal.map(\.theta).reduce(0, +) / Float(frontal.count)
                self.frontBeta  = frontal.map(\.beta).reduce(0, +)  / Float(frontal.count)
                self.bandUpdateCount += 1
            }
            self.scorer.process(powers)
        }

        scorer.onResult = { [weak self] result in
            self?.depth = result
        }

        client.startScan()
    }

    func connectFirst() {
        if let m = IXNMuseManagerIos.sharedManager().getMuses().first {
            client.connect(to: m)
            scorer.startCalibration()
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
                    } else {
                        LabeledContent("Calibrating…",
                                       value: "\(Int(probe.depth.calibrationProgress * 60))s / 60s")
                        ProgressView(value: Double(probe.depth.calibrationProgress))
                    }
                }
            }
            .navigationTitle("Muse++ — Gate 2")
        }
    }

    private func scoreColor(_ s: Float) -> Color {
        s > 0.65 ? .green : s > 0.4 ? .yellow : .red
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
