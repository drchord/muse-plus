import Foundation
import Combine

final class MuseClient: NSObject {

    // MARK: - Public publishers
    let discoveredMuses = CurrentValueSubject<[IXNMuse], Never>([])
    let connectionState = CurrentValueSubject<IXNConnectionState, Never>(.unknown)
    let eegPacket       = PassthroughSubject<EEGPacket, Never>()
    let fitCheck        = CurrentValueSubject<FitCheckSnapshot, Never>(.zero)
    let battery         = CurrentValueSubject<Double, Never>(0)
    let errors          = PassthroughSubject<MuseClientError, Never>()

    // MARK: - Internals
    private let manager: IXNMuseManagerIos
    private var connectedMuse: IXNMuse?
    private let queue = DispatchQueue(label: "com.drchord.museplus.client", qos: .userInitiated)

    override init() {
        self.manager = IXNMuseManagerIos.sharedManager()
        super.init()
        manager.setMuseListener(self)
    }

    // MARK: - Public API

    func startScan() {
        manager.startListening()
    }

    func stopScan() {
        manager.stopListening()
    }

    func connect(to muse: IXNMuse) {
        queue.async {
            self.disconnectInternal()
            self.connectedMuse = muse
            // Preset must be set BEFORE registering listeners (SDK requirement)
            muse.setPreset(.preset53)   // Muse S Athena — try .preset50/.preset55 if no packets
            muse.register(self as IXNMuseConnectionListener?)
            muse.register(self as IXNMuseDataListener?, type: .eeg)
            muse.register(self as IXNMuseDataListener?, type: .hsi)
            muse.register(self as IXNMuseDataListener?, type: .battery)
            muse.runAsynchronously()
        }
    }

    func disconnect() {
        queue.async { self.disconnectInternal() }
        DispatchQueue.main.async { self.connectionState.send(.disconnected) }
    }

    // MARK: - Private

    private func disconnectInternal() {
        if let m = connectedMuse {
            m.disconnect()
            m.unregisterAllListeners()
            connectedMuse = nil
        }
    }
}

// MARK: - IXNMuseListener (discovery)

extension MuseClient: IXNMuseListener {
    func museListChanged() {
        let muses = (manager.getMuses() as? [IXNMuse]) ?? []
        DispatchQueue.main.async { self.discoveredMuses.send(muses) }
    }
}

// MARK: - IXNMuseConnectionListener

extension MuseClient: IXNMuseConnectionListener {
    func receiveMuseConnectionPacket(_ packet: IXNMuseConnectionPacket, muse: IXNMuse?) {
        DispatchQueue.main.async { self.connectionState.send(packet.currentConnectionState) }
    }
}

// MARK: - IXNMuseDataListener

extension MuseClient: IXNMuseDataListener {
    func receiveMuseDataPacket(_ packet: IXNMuseDataPacket?, muse: IXNMuse?) {
        guard let p = packet else { return }
        switch p.packetType() {
        case .eeg:      handleEEG(p)
        case .hsi:      handleHorseshoe(p)
        case .battery:  handleBattery(p)
        default:        break
        }
    }

    func receiveMuseArtifactPacket(_ packet: IXNMuseArtifactPacket, muse: IXNMuse?) {
        // artifact handling added in Gate 2
    }

    private func handleEEG(_ p: IXNMuseDataPacket) {
        let channels: [Float] = [
            Float(p.getEegChannelValue(.eeg1)),
            Float(p.getEegChannelValue(.eeg2)),
            Float(p.getEegChannelValue(.eeg3)),
            Float(p.getEegChannelValue(.eeg4)),
        ]
        let pkt = EEGPacket(timestamp: Date().timeIntervalSinceReferenceDate, channels: channels)
        DispatchQueue.main.async { self.eegPacket.send(pkt) }
    }

    private func handleHorseshoe(_ p: IXNMuseDataPacket) {
        // Horseshoe values: 1.0 = good contact, 2.0+ = poor
        let good: (IXNEeg) -> Bool = { p.getEegChannelValue($0) < 2.0 }
        let snap = FitCheckSnapshot(
            tp9:  good(.eeg1),
            af7:  good(.eeg2),
            af8:  good(.eeg3),
            tp10: good(.eeg4)
        )
        DispatchQueue.main.async { self.fitCheck.send(snap) }
    }

    private func handleBattery(_ p: IXNMuseDataPacket) {
        let pct = p.getBatteryValue(.batteryChargePercentage)
        DispatchQueue.main.async { self.battery.send(pct) }
    }
}
