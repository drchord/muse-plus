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

// MARK: - Probe (Gate 1 debug harness)

final class Probe: ObservableObject {
    @Published var muses: [String] = []
    @Published var connection: String = "—"
    @Published var fit: FitCheckSnapshot = .zero
    @Published var lastEEG: [Float] = []
    @Published var battery: Double = 0
    @Published var packetCount: Int = 0

    let client = MuseClient()
    private var bag = Set<AnyCancellable>()

    func start() {
        client.discoveredMuses
            .map { $0.compactMap { $0.getName() } }
            .receive(on: RunLoop.main)
            .assign(to: &$muses)

        client.connectionState
            .map { s in "\(s.rawValue)" }
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
                self?.lastEEG = pkt.channels
                self?.packetCount += 1
            }
            .store(in: &bag)

        client.startScan()
    }

    func connectFirst() {
        if let m = IXNMuseManagerIos.sharedManager().getMuses().first {
            client.connect(to: m)
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
                        ForEach(probe.muses, id: \.self) { name in
                            Text(name)
                        }
                        Button("Connect first") { probe.connectFirst() }
                            .foregroundStyle(.blue)
                    }
                }
                Section("Connection") {
                    LabeledContent("State", value: probe.connection)
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
            }
            .navigationTitle("Muse Plus — Gate 1 Probe")
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
