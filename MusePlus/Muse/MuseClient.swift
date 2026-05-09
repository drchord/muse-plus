import Foundation
import Combine
import OSLog

final class MuseClient: NSObject {

    // MARK: - Public publishers
    let discoveredMuses  = CurrentValueSubject<[IXNMuse], Never>([])
    let connectionState  = CurrentValueSubject<IXNConnectionState, Never>(.unknown)
    let eegPacket        = PassthroughSubject<EEGPacket, Never>()
    let fitCheck         = CurrentValueSubject<FitCheckSnapshot, Never>(.zero)
    let hsiRaw           = PassthroughSubject<[Double], Never>()
    let battery          = CurrentValueSubject<Double, Never>(0)
    let errors           = PassthroughSubject<MuseClientError, Never>()
    // Fires true when a blink or jaw-clench artifact is detected.
    let artifactDetected = PassthroughSubject<Bool, Never>()
    // Heart rate in BPM from PPG Green channel; 0 = no valid reading yet.
    let heartRate        = CurrentValueSubject<Double, Never>(0)
    // Raw (OPTICS7 + OPTICS8) / 2 sample at 64 Hz — Athena only. Feeds HRVPipeline.
    let opticsRawSample  = PassthroughSubject<Double, Never>()

    // MARK: - Internals
    private let manager: IXNMuseManagerIos
    private var connectedMuse: IXNMuse?
    private let queue = DispatchQueue(label: "com.drchord.museplus.client", qos: .userInitiated)
    // PPG heart-rate state (accessed only from SDK callback thread)
    private var ppgBuffer:  [Double] = []
    private var lastBpmTs:  TimeInterval = 0
    // Muse S (2019) PPG rate is 64 Hz; window = 8s
    private static let ppgSampleRate: Double = 64.0
    private static let ppgWindowSize: Int    = 512

    // Athena (Ms03) requires preset 1041 (8 EEG @ 256Hz + 16 Optics @ 64Hz) — preset 21
    // is rejected by Athena firmware and would leave headband disconnected.
    // Tracks whether model-appropriate preset has been applied for current session.
    private var presetAppliedFor: IXNMuseModel?
    // Remembered after applyPresetForModel; drives 8-channel EEG read in handleEEG.
    private var connectedMuseModel: IXNMuseModel?
    // Timestamp of last received .notchFilteredEeg packet (SDK callback thread only — no lock needed).
    // Used to gate the .eeg fallback: if .notchFilteredEeg has not arrived in 2s, .eeg is active.
    // Boolean hasNotchEeg was insufficient: Athena at preset1041 emits ONE notch packet on connect
    // then stops, locking hasNotchEeg = true and permanently blocking the .eeg fallback.
    private var lastNotchEegTs: TimeInterval = 0
    // Rate-limit quality-based suppression: isGood fires at 10 Hz; without gating, poor frontal
    // contact during settle-in floods suppressWindows and permanently blocks the EEG pipeline.
    // 5s minimum between successive quality-triggered artifact events is sufficient — artifacts
    // suppress 4 windows × 0.5s = 2s, so a new trigger is only needed if problem persists.
    private var lastQualitySuppression: TimeInterval = 0
    // B80 (B6): set after first successful .connected. Triggers defensive re-registration
    // on subsequent .connected events since some SDK versions lose listeners after reconnect.
    private var wasConnectedBefore = false

    // MARK: - EEG packet telemetry (write on SDK callback thread; read from any thread)
    // lastEegPacketTime: updated on every .notchFilteredEeg / .eeg packet. Used post-disconnect
    // to determine whether EEG stalled while the BLE connection appeared up.
    static var lastEegPacketTime: Date = .distantPast
    // B83 — most recent inter-packet gap in milliseconds. Atomic; written on SDK thread,
    // read by Probe.addSample to populate per-sample `packetGapMs`. Replaces the B80 gap
    // field that was nil for every sample (never wired into Probe).
    static var lastPacketGapMs: Float = 0
    // Ring buffer of recent EEG packet timestamps for rolling 30-s count.
    // Access must be serialised — use the eegStatsLock.
    private var eegPacketTimestamps: [Date] = []
    private let eegStatsLock = NSLock()

    // Returns (count of packets received in last 30s, seconds since the most recent packet).
    // Safe to call from any thread.
    func eegPacketRollingStats() -> (count30s: Int, lastPacketAge: TimeInterval) {
        eegStatsLock.lock()
        defer { eegStatsLock.unlock() }
        let cutoff = Date().addingTimeInterval(-30)
        let recent = eegPacketTimestamps.filter { $0 > cutoff }
        let age    = Date().timeIntervalSince(MuseClient.lastEegPacketTime)
        return (recent.count, age)
    }

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

    // preservePreset: pass true for auto-reconnect (preset already applied to hardware,
    // re-applying causes another disconnect/reconnect loop). Pass false (default) only
    // for user-initiated connects where model detection should start fresh.
    func connect(to muse: IXNMuse, preservePreset: Bool = false) {
        // SDK requires setup on main thread (matches reference app pattern)
        assert(Thread.isMainThread)
        manager.stopListening()
        disconnectInternal()
        connectedMuse = muse
        muse.unregisterAllListeners()
        registerAllListeners(on: muse)
        if !preservePreset {
            presetAppliedFor   = nil
            connectedMuseModel = nil
            wasConnectedBefore = false  // B80 (B6): fresh user-initiated session
        }
        muse.runAsynchronously()
    }

    // B80 (B6): Idempotent listener registration. Called from connect() on initial connect
    // AND re-called from IXNMuseConnectionListener.receive() on subsequent .connected events
    // when wasConnectedBefore is set. Some Muse SDK versions lose listener state after
    // a disconnect/reconnect cycle — re-registering defensively costs nothing.
    //
    // B4 NOTE — CBCentralManager state restoration:
    //   IXNMuseManagerIos fully abstracts CBCentralManager. The SDK does NOT expose the
    //   CBCentralManager instance, nor does it accept a CBCentralManagerOptionRestoreIdentifierKey.
    //   CoreBluetooth state restoration (centralManager(_:willRestoreState:)) therefore CANNOT be
    //   implemented at the app layer. The `bluetooth-central` UIBackgroundMode in Info.plist is
    //   still required and valuable: it keeps the BLE radio alive while the app is suspended,
    //   and the SDK's own CBCentralManager likely uses it internally. If InterAxon ever exposes
    //   a restoration identifier API we can hook in here.
    private func registerAllListeners(on muse: IXNMuse) {
        muse.register(self as IXNMuseConnectionListener?)
        muse.register(self as IXNMuseDataListener?, type: .notchFilteredEeg)
        muse.register(self as IXNMuseDataListener?, type: .hsiPrecision)
        muse.register(self as IXNMuseDataListener?, type: .battery)
        muse.register(self as IXNMuseDataListener?, type: .artifacts)
        muse.register(self as IXNMuseDataListener?, type: .isGood)
        muse.register(self as IXNMuseDataListener?, type: .eeg)
        muse.register(self as IXNMuseDataListener?, type: .ppg)
        muse.register(self as IXNMuseDataListener?, type: .optics)
        muse.register(self as IXNMuseDataListener?, type: .accelerometer)
        // B77: SDK Muse Elements packets — used for cross-validation against our pipeline.
        // Emitted at 10 Hz per Interaxon docs. Lightweight; no impact on existing handlers.
        muse.register(self as IXNMuseDataListener?, type: .alphaAbsolute)
        muse.register(self as IXNMuseDataListener?, type: .betaAbsolute)
        muse.register(self as IXNMuseDataListener?, type: .thetaAbsolute)
        muse.register(self as IXNMuseDataListener?, type: .deltaAbsolute)
        muse.register(self as IXNMuseDataListener?, type: .gammaAbsolute)
        muse.register(self as IXNMuseDataListener?, type: .alphaRelative)
        muse.register(self as IXNMuseDataListener?, type: .betaRelative)
        muse.register(self as IXNMuseDataListener?, type: .thetaRelative)
        muse.register(self as IXNMuseDataListener?, type: .alphaScore)
        muse.register(self as IXNMuseDataListener?, type: .betaScore)
        muse.register(self as IXNMuseDataListener?, type: .thetaScore)
    }

    func disconnect() {
        queue.async { self.disconnectInternal() }
        DispatchQueue.main.async {
            self.connectionState.send(.disconnected)
            self.heartRate.send(0)
        }
    }

    // MARK: - Private

    private func disconnectInternal() {
        if let m = connectedMuse {
            m.disconnect()
            m.unregisterAllListeners()
            connectedMuse = nil
        }
        ppgBuffer.removeAll()
        lastBpmTs = 0
        // presetAppliedFor and connectedMuseModel intentionally NOT reset here.
        // connect(to:preservePreset:) controls them: user-initiated connect resets both;
        // auto-reconnect preserves them to avoid re-applying preset and the resulting
        // disconnect/reconnect loop that delays EEG flow past the calibration window.
        lastNotchEegTs = 0       // reset: .eeg fallback active until .notchFilteredEeg confirms
        lastQualitySuppression = 0
        // wasConnectedBefore intentionally NOT reset here — it tracks whether ANY .connected
        // event has fired for this IXNMuse object so reconnect re-registers listeners.
        // It resets on user-initiated connect (see connect(to:preservePreset:) call path).
    }

    // Choose the right preset for the connected hardware. Called once per session
    // after the first .connected state transition. Setting a preset triggers a
    // disconnect/reconnect cycle on the headband per SDK contract.
    private func applyPresetForModel(_ muse: IXNMuse) {
        // IXNMuse exposes getModel() directly; no need to go through configuration.
        let model = muse.getModel()
        guard presetAppliedFor != model else { return }
        if model == .ms03 {
            // Athena: 8 EEG @ 256Hz/14-bit + 16 Optics @ 64Hz, low power. Provides
            // canonical EEG1-4 + AUX1-4 plus Optics for PPG/fNIRS.
            // Heart rate via legacy PPG path will read empty on Athena until
            // Phase A3 lands the Optics-derived HR pipeline.
            muse.setPreset(.preset1041)
        } else {
            // Muse S 2019/2021 + Muse 2 + older: preset21 ships 4 EEG + accelerometer,
            // PPG via separate ppg packet type. Preserves Build 54 behavior exactly.
            muse.setPreset(.preset21)
        }
        presetAppliedFor = model
        connectedMuseModel = model
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
        let state = packet.currentConnectionState
        Telemetry.connection.notice("state=\(state.rawValue, privacy: .public)")
        DispatchQueue.main.async { self.connectionState.send(state) }
        // On first .connected of this session, query model and apply correct preset.
        // Subsequent .connected (after preset change disconnect/reconnect) skips,
        // because presetAppliedFor is now set.
        if state == .connected, let m = muse {
            if presetAppliedFor == nil {
                // First connect this session: apply hardware preset.
                // setPreset must run on main thread (matches connect() pattern)
                DispatchQueue.main.async { [weak self] in self?.applyPresetForModel(m) }
            } else if wasConnectedBefore {
                // B80 (B6): subsequent .connected after reconnect — re-register listeners
                // defensively. Some SDK versions silently drop listener state on reconnect.
                // unregisterAllListeners first to avoid duplicate callbacks.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    m.unregisterAllListeners()
                    self.registerAllListeners(on: m)
                    Telemetry.connection.notice("re-registered listeners after reconnect")
                }
            }
            wasConnectedBefore = true
        }
    }
}

// MARK: - IXNMuseDataListener

extension MuseClient: IXNMuseDataListener {
    func receive(_ packet: IXNMuseDataPacket?, muse: IXNMuse?) {
        guard let p = packet else { return }
        switch p.packetType() {
        case .notchFilteredEeg:
            lastNotchEegTs = Date().timeIntervalSinceReferenceDate
            handleEEG(p)
        case .eeg:
            // Active when .notchFilteredEeg has not arrived in 2s. Handles Athena (preset1041)
            // which may send one notch packet on connect then emit EEG only via .eeg.
            if Date().timeIntervalSinceReferenceDate - lastNotchEegTs > 2.0 { handleEEG(p) }
        case .hsiPrecision:     handleHorseshoe(p)
        case .battery:          handleBattery(p)
        case .isGood:           handleIsGood(p)
        case .ppg:              handlePpg(p)           // heart rate — legacy Muse S/2
        case .optics:           handleOptics(p)        // heart rate + fNIRS — Athena only
        case .accelerometer:    handleAccelerometer(p) // motion artifact
        // B77: SDK Elements — feed values to ElementsTracker. Per-channel array;
        // ElementsTracker averages across channels. NaN values dropped per Muse docs
        // ("transmitting nothing rather than NaN-filled packets" varies by SDK version).
        case .alphaAbsolute, .betaAbsolute, .thetaAbsolute, .deltaAbsolute, .gammaAbsolute,
             .alphaRelative, .betaRelative, .thetaRelative,
             .alphaScore, .betaScore, .thetaScore:
            ElementsTracker.shared.ingest(p.values(), type: p.packetType())
        default:                break
        }
    }

    func receive(_ packet: IXNMuseArtifactPacket, muse: IXNMuse?) {
        guard packet.blink || packet.jawClench else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastQualitySuppression >= 5.0 else { return }
        lastQualitySuppression = now
        DispatchQueue.main.async { self.artifactDetected.send(true) }
    }

    private func handleEEG(_ p: IXNMuseDataPacket) {
        // Canonical 4 channels on all hardware.
        var channels: [Float] = [
            Float(p.getEegChannelValue(.EEG1)),
            Float(p.getEegChannelValue(.EEG2)),
            Float(p.getEegChannelValue(.EEG3)),
            Float(p.getEegChannelValue(.EEG4)),
        ]
        // Athena (MS-03) adds AUX1-4 (indices 4-7) for 8-channel EEG @ 256Hz/14-bit.
        if connectedMuseModel == .ms03 {
            channels += [
                Float(p.getEegChannelValue(.AUX1)),
                Float(p.getEegChannelValue(.AUX2)),
                Float(p.getEegChannelValue(.AUX3)),
                Float(p.getEegChannelValue(.AUX4)),
            ]
        }
        // No amplitude threshold here. Athena at preset1041 returns raw ADC counts (14-bit,
        // ~0–16383) not calibrated µV, so any fixed threshold rejects nearly every packet and
        // starves the FFT buffer → Windows stays 0 → calibration never completes.
        // computeWindow() removes DC mean before FFT, so ADC offset does not corrupt band powers.
        // Artifact suppression is handled by SDK blink/jaw detection + handleIsGood (rate-limited).
        let pkt = EEGPacket(timestamp: Date().timeIntervalSinceReferenceDate, channels: channels)
        // Update rolling telemetry — no per-packet log (too noisy at 256 Hz).
        let now = Date()
        // B83 — compute inter-packet gap before updating the timestamp.
        // Skip the very first packet (lastEegPacketTime == .distantPast).
        if MuseClient.lastEegPacketTime != .distantPast {
            let dtMs = now.timeIntervalSince(MuseClient.lastEegPacketTime) * 1000.0
            MuseClient.lastPacketGapMs = Float(dtMs)
        }
        MuseClient.lastEegPacketTime = now
        // B83 — sidecar denoise: feed packet to 1-sec window buffer. Stats emit to NDJSON.
        // Live pipeline unchanged; cleaned signal is measurement-only for now.
        EEGWindowBuffer.shared.ingest(pkt)
        eegStatsLock.lock()
        eegPacketTimestamps.append(now)
        if eegPacketTimestamps.count > 256 * 30 { // cap ring at 30s × 256Hz worst-case
            eegPacketTimestamps.removeFirst(eegPacketTimestamps.count - 256 * 30)
        }
        eegStatsLock.unlock()
        DispatchQueue.main.async { self.eegPacket.send(pkt) }
    }

    private func handleHorseshoe(_ p: IXNMuseDataPacket) {
        let raw = p.values()
        guard raw.count >= 4 else { return }
        let vals = (0..<4).map { raw[$0].doubleValue }
        // 1=good, 2=mediocre, 4=no contact
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

    // IsGood: 4 values (1=good, 0=bad) per EEG channel, emitted at 10 Hz.
    // If frontal channels (AF7=idx1, AF8=idx2) are bad, trigger artifact suppression.
    // Rate-limited: max one suppression event per 5s to prevent settle-in flood.
    private func handleIsGood(_ p: IXNMuseDataPacket) {
        let vals = p.values()
        guard vals.count >= 4 else { return }
        let af7Good = vals[1].doubleValue > 0.5
        let af8Good = vals[2].doubleValue > 0.5
        guard !af7Good || !af8Good else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastQualitySuppression >= 5.0 else { return }
        lastQualitySuppression = now
        DispatchQueue.main.async { self.artifactDetected.send(true) }
    }

    // PPG at ~64 Hz. AMBIENT = Green on Muse S (2019). Compute BPM every 2s from 8s window.
    // Dispatch to queue to serialize buffer access with disconnectInternal (avoids data race).
    private func handlePpg(_ p: IXNMuseDataPacket) {
        let sample = p.getPpgChannelValue(.AMBIENT)
        guard sample.isFinite else { return }
        queue.async { [self] in
            ppgBuffer.append(sample)
            if ppgBuffer.count > MuseClient.ppgWindowSize { ppgBuffer.removeFirst() }
            let now = Date().timeIntervalSinceReferenceDate
            guard ppgBuffer.count == MuseClient.ppgWindowSize, now - lastBpmTs >= 2.0 else { return }
            lastBpmTs = now
            let bpm = computeBPM(ppgBuffer)
            guard bpm > 30 && bpm < 200 else { return }
            DispatchQueue.main.async { self.heartRate.send(bpm) }
        }
    }

    // Athena Optics heart-rate path. 850 nm inner channels (OPTICS7 left, OPTICS8 right)
    // follow blood-volume pulse. Average both for SNR. Feed same autocorrelation BPM
    // pipeline as legacy PPG — unit-agnostic (periodic signal detection only).
    // Legacy devices have no Optics hardware; this method never fires for them.
    private func handleOptics(_ p: IXNMuseDataPacket) {
        let left  = p.getOpticsChannelValue(.OPTICS7)  // 850 nm inner left
        let right = p.getOpticsChannelValue(.OPTICS8)  // 850 nm inner right
        guard left.isFinite, right.isFinite else { return }
        let sample = (left + right) * 0.5
        // Feed HRV pipeline before queue hop — PassthroughSubject.send is thread-safe.
        opticsRawSample.send(sample)
        queue.async { [self] in
            ppgBuffer.append(sample)
            if ppgBuffer.count > MuseClient.ppgWindowSize { ppgBuffer.removeFirst() }
            let now = Date().timeIntervalSinceReferenceDate
            guard ppgBuffer.count == MuseClient.ppgWindowSize, now - lastBpmTs >= 2.0 else { return }
            lastBpmTs = now
            let bpm = computeBPM(ppgBuffer)
            guard bpm > 30 && bpm < 200 else { return }
            DispatchQueue.main.async { self.heartRate.send(bpm) }
        }
    }

    private func computeBPM(_ buf: [Double]) -> Double {
        let n = buf.count
        let fs = MuseClient.ppgSampleRate

        // 1. De-mean
        let mu = buf.reduce(0.0, +) / Double(n)
        var sig = buf.map { $0 - mu }

        // 2. Baseline wander removal: subtract causal 1-s MA (64-tap box high-pass).
        //    Removes breathing-driven amplitude modulation (~0.2 Hz) that biases
        //    any amplitude-based detection downstream.
        var trend = [Double](repeating: 0, count: n)
        var bwSum = 0.0
        let hpWin = Int(fs)  // 1 s = 64 samples
        for i in 0..<n {
            bwSum += sig[i]
            if i >= hpWin { bwSum -= sig[i - hpWin] }
            trend[i] = bwSum / Double(min(i + 1, hpWin))
        }
        for i in 0..<n { sig[i] -= trend[i] }

        // 3. Low-pass: 8-tap causal box filter removes HF noise above the heart-rate band.
        var lp = [Double](repeating: 0, count: n)
        var lpSum = 0.0
        let lpWin = 8
        for i in 0..<n {
            lpSum += sig[i]
            if i >= lpWin { lpSum -= sig[i - lpWin] }
            lp[i] = lpSum / Double(min(i + 1, lpWin))
        }

        // 4. Autocorrelation over physiological lag range.
        //    Lags: 19 samples (200 BPM) → 128 samples (30 BPM) at 64 Hz.
        //    ~56 K MACs per call, called every 2 s — negligible CPU.
        //    AC is robust to isolated noise spikes unlike peak detection;
        //    periodic heartbeat creates a clear AC peak at the beat interval.
        let minLag = Int((fs * 60.0 / 200.0).rounded(.up))   // 19
        let maxLag = Int((fs * 60.0 / 30.0).rounded(.down))  // 128
        guard maxLag < n else { return 0 }

        let power = lp.reduce(0.0) { $0 + $1 * $1 } / Double(n)
        guard power > 0 else { return 0 }

        var bestLag = minLag
        var bestAC = -Double.infinity
        for lag in minLag...maxLag {
            let usable = n - lag
            var ac = 0.0
            for i in 0..<usable { ac += lp[i] * lp[i + lag] }
            ac /= Double(usable)
            if ac > bestAC { bestAC = ac; bestLag = lag }
        }

        // 5. Quality gate: AC peak must be > 20% of signal power.
        //    Weak ratio = aperiodic noise or flat signal → suppress.
        guard bestAC / power > 0.20 else { return 0 }

        return fs * 60.0 / Double(bestLag)
    }

    // Head motion > 0.25g deviation from resting 1g magnitude triggers artifact suppression.
    // Rate-limited via lastQualitySuppression: same 5s gate as handleIsGood.
    private func handleAccelerometer(_ p: IXNMuseDataPacket) {
        let x: Double = p.getAccelerometerValue(.X)
        let y: Double = p.getAccelerometerValue(.Y)
        let z: Double = p.getAccelerometerValue(.Z)
        let sumSq: Double = x*x + y*y + z*z
        let magnitude: Double = sqrt(sumSq)
        guard abs(magnitude - 1.0) > 0.25 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastQualitySuppression >= 5.0 else { return }
        lastQualitySuppression = now
        DispatchQueue.main.async { self.artifactDetected.send(true) }
    }
}
