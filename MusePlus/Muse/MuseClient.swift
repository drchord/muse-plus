import Foundation
import Combine

final class MuseClient: NSObject {

    // MARK: - Public publishers
    let discoveredMuses = CurrentValueSubject<[IXNMuse], Never>([])
    let connectionState = CurrentValueSubject<IXNConnectionState, Never>(.unknown)
    let eegPacket       = PassthroughSubject<EEGPacket, Never>()
    let fitCheck        = CurrentValueSubject<FitCheckSnapshot, Never>(.zero)
    let hsiRaw          = PassthroughSubject<[Double], Never>()
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
        // SDK requires setup on main thread (matches reference app pattern)
        assert(Thread.isMainThread)
        manager.stopListening()
        disconnectInternal()
        connectedMuse = muse
        muse.unregisterAllListeners()
        muse.register(self as IXNMuseConnectionListener?)
        muse.register(self as IXNMuseDataListener?, type: .eeg)
        muse.register(self as IXNMuseDataListener?, type: .hsiPrecision)
        muse.register(self as IXNMuseDataListener?, type: .battery)
        muse.setPreset(.preset21)   // default for muse2019 (Muse S Athena) — no preset change = no disconnect cycle
        muse.runAsynchronously()
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
        let muses = manager.getMuses() as! [IXNMuse]
        DispatchQueue.main.async { self.discoveredMuses.send(muses) }
    }
}

// MARK: - IXNMuseConnectionListener

extension MuseClient: IXNMuseConnectionListener {
    func receive(_ packet: IXNMuseConnectionPacket, muse: IXNMuse?) {
        DispatchQueue.main.async { self.connectionState.send(packet.currentConnectionState) }
    }
}

// MARK: - IXNMuseDataListener

extension MuseClient: IXNMuseDataListener {
    func receive(_ packet: IXNMuseDataPacket?, muse: IXNMuse?) {
        guard let p = packet else { return }
        switch p.packetType() {
        case .eeg:      handleEEG(p)
        case .hsiPrecision: handleHorseshoe(p)
        case .battery:  handleBattery(p)
        default:        break
        }
    }

    func receive(_ packet: IXNMuseArtifactPacket, muse: IXNMuse?) {
        // artifact handling added in Gate 2
    }

    private func handleEEG(_ p: IXNMuseDataPacket) {
        let channels: [Float] = [
            Float(p.getEegChannelValue(.EEG1)),
            Float(p.getEegChannelValue(.EEG2)),
            Float(p.getEegChannelValue(.EEG3)),
            Float(p.getEegChannelValue(.EEG4)),
        ]
        let pkt = EEGPacket(timestamp: Date().timeIntervalSinceReferenceDate, channels: channels)
        DispatchQueue.main.async { self.eegPacket.send(pkt) }
    }

    private func handleHorseshoe(_ p: IXNMuseDataPacket) {
        // hsiPrecision values are 1/2/4 quality indicators — use values() not getEegChannelValue
        // getEegChannelValue applies ADC→µV conversion which corrupts non-EEG packets
        let raw = p.values()
        guard raw.count >= 4 else { return }
        let vals = (0..<4).map { raw[$0].doubleValue }
        let snap = FitCheckSnapshot(
            tp9:  vals[0] < 2.0,
            af7:  vals[1] < 2.0,
            af8:  vals[2] < 2.0,
            tp10: vals[3] < 2.0
        )
        DispatchQueue.main.async {
            self.hsiRaw.send(vals)
            self.fitCheck.send(snap)
        }
    }

    private func handleBattery(_ p: IXNMuseDataPacket) {
        let pct = p.getBatteryValue(.chargePercentageRemaining)
        DispatchQueue.main.async { self.battery.send(pct) }
    }
}
