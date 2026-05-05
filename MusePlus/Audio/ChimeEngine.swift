import AVFoundation

final class ChimeEngine {
    static let shared = ChimeEngine()

    private let engine     = AVAudioEngine()
    private let player     = AVAudioPlayerNode()
    private let reverb     = AVAudioUnitReverb()
    private let sampleRate: Double = 44100
    // 53-sample Haas delay on R channel: ~1.2 ms — stereo width without comb filtering
    private let haasSamples: Int = 53

    init() {
        // Explicit stereo format — MUST be explicit to survive BT route changes
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 25
        engine.attach(player)
        engine.attach(reverb)
        engine.connect(player, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)
        configureSession()
        try? engine.start()
        observeAudio()
    }

    // MARK: - Public API

    /// Enter deep state: rich 432 Hz bowl — warm, welcoming, celebratory.
    func playEnterDeep() {
        reverb.wetDryMix = 28
        scheduleBowl(fundamental: 432, decayRate: 0.8, duration: 4.0, amplitude: 0.32)
        scheduleDuck(over: 4.5)
    }

    /// Exit deep state: 288 Hz (perfect fifth below 432 Hz) — lower, softer acknowledgement.
    func playExitDeep() {
        reverb.wetDryMix = 22
        scheduleBowl(fundamental: 288, decayRate: 1.4, duration: 2.5, amplitude: 0.24)
        scheduleDuck(over: 3.0)
    }

    /// Contact lost: 660 Hz dry ping — brief, alert, attention-grabbing.
    func playContactLost() {
        reverb.wetDryMix = 5
        scheduleBowl(fundamental: 660, decayRate: 3.5, duration: 1.2, amplitude: 0.50)
        scheduleDuck(over: 1.5)
    }

    /// Contact restored: 528 Hz then 660 Hz ascending double bowl — reassurance.
    func playContactRestored() {
        reverb.wetDryMix = 18
        scheduleBowl(fundamental: 528, decayRate: 1.6, duration: 1.8, amplitude: 0.28)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.scheduleBowl(fundamental: 660, decayRate: 2.0, duration: 1.5, amplitude: 0.22)
        }
        scheduleDuck(over: 3.0)
    }

    /// In-session guidance check-in: 396 Hz gentle bowl — soft reminder, non-disruptive.
    func playCheckIn() {
        reverb.wetDryMix = 20
        scheduleBowl(fundamental: 396, decayRate: 1.2, duration: 2.0, amplitude: 0.20)
        scheduleDuck(over: 2.5)
    }

    /// Timer end: three descending gong strikes.
    func playTimerEnd() {
        reverb.wetDryMix = 35
        scheduleGong(fundamental: 84, decayRate: 0.20, duration: 7.0, amplitude: 0.70)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.scheduleGong(fundamental: 84, decayRate: 0.20, duration: 7.0, amplitude: 0.50)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.scheduleGong(fundamental: 84, decayRate: 0.20, duration: 7.0, amplitude: 0.35)
        }
        scheduleDuck(over: 13.0)
    }

    // MARK: - Bowl synthesis (stereo, per-partial decay, Haas)

    private func scheduleBowl(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        guard let buf = stereoBuffer(duration: duration) else { return }
        let L    = buf.floatChannelData![0]
        let R    = buf.floatChannelData![1]
        let n    = Int(buf.frameLength)
        // Per-partial ratios and decay multipliers (measured from real Tibetan bowls)
        // Ratio, amplitude weight, decay multiplier
        let partials: [(freq: Double, amp: Double, decay: Double)] = [
            (1.000, 1.00, 1.0),   // fundamental
            (2.756, 0.45, 2.2),   // second partial — decays 2.2× faster
            (5.404, 0.20, 4.1),   // third partial
            (8.900, 0.08, 7.8),   // fourth partial — nearly gone by 0.5s
        ]
        // 25ms linear attack to avoid click
        let attackSamples = Int(0.025 * sampleRate)
        for i in 0..<n {
            let tL = Double(i) / sampleRate
            let tR = Double(max(0, i - haasSamples)) / sampleRate
            let attack = i < attackSamples ? Double(i) / Double(attackSamples) : 1.0
            var sL = 0.0, sR = 0.0
            for p in partials {
                let eL = exp(-decayRate * p.decay * tL)
                let eR = exp(-decayRate * p.decay * tR)
                sL += p.amp * eL * sin(2 * .pi * fundamental * p.freq * tL)
                sR += p.amp * eR * sin(2 * .pi * fundamental * p.freq * tR)
            }
            L[i] = Float(sL * attack * amplitude)
            R[i] = Float(sR * attack * amplitude)
        }
        schedule(buf)
    }

    // MARK: - Gong synthesis (stereo, physical impact model)

    private func scheduleGong(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        guard let buf = stereoBuffer(duration: duration) else { return }
        let L    = buf.floatChannelData![0]
        let R    = buf.floatChannelData![1]
        let n    = Int(buf.frameLength)
        // Gong partials: inharmonic ratios, faster-decaying upper partials
        let partials: [(freq: Double, amp: Double, decay: Double)] = [
            (1.000, 1.00, 0.40),
            (1.516, 0.70, 0.55),
            (2.871, 0.35, 0.80),
            (4.465, 0.18, 1.10),
            (6.122, 0.10, 1.50),
        ]
        let attackSamples = Int(0.08 * sampleRate)
        for i in 0..<n {
            let tL = Double(i) / sampleRate
            let tR = Double(max(0, i - haasSamples)) / sampleRate
            let attack = i < attackSamples ? Double(i) / Double(attackSamples) : 1.0
            var sL = 0.0, sR = 0.0
            for p in partials {
                let eL = exp(-p.decay * decayRate * tL)
                let eR = exp(-p.decay * decayRate * tR)
                sL += p.amp * eL * sin(2 * .pi * fundamental * p.freq * tL)
                sR += p.amp * eR * sin(2 * .pi * fundamental * p.freq * tR)
            }
            L[i] = Float(sL * attack * amplitude)
            R[i] = Float(sR * attack * amplitude)
        }
        schedule(buf)
    }

    // MARK: - Helpers

    private func stereoBuffer(duration: Double) -> AVAudioPCMBuffer? {
        let n   = AVAudioFrameCount(sampleRate * duration)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)
        buf?.frameLength = n
        return buf
    }

    private func schedule(_ buf: AVAudioPCMBuffer) {
        ensureRunning()
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Duck soundscape while chime plays; unduck after it finishes.
    private func scheduleDuck(over duration: Double) {
        SoundscapePlayer.shared.duck(to: 0.18, fadeDuration: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            SoundscapePlayer.shared.unduck(fadeDuration: 1.5)
        }
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeAudio() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            // Delay lets iOS finish the route-change before restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.ensureRunning()
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let raw  = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            self.configureSession()
            self.ensureRunning()
        }
    }
}
