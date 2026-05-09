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
        // B83: Apple-recommended prepare() before start() — pre-allocates audio buffers,
        // reduces first-buffer latency, and stabilizes engine state across route changes.
        engine.prepare()
        try? engine.start()
        observeAudio()
    }

    // MARK: - Volume

    var chimeVolume: Float {
        get {
            // B83 round-4 — UserDefaults can store Float as NSNumber-Double depending
            // on call site. `as? Float` fails when the underlying type is Double.
            // Robust read across types; clamps to [0,1].
            let raw = UserDefaults.standard.object(forKey: "chimeVolume")
            if let f = raw as? Float  { return max(0, min(1, f)) }
            if let d = raw as? Double { return max(0, min(1, Float(d))) }
            if let n = raw as? NSNumber { return max(0, min(1, n.floatValue)) }
            return 0.7
        }
        set { UserDefaults.standard.set(newValue, forKey: "chimeVolume") }
    }

    // MARK: - B83 state introspection (for SessionRecorder.appendAudioState)
    var isEngineRunning: Bool { engine.isRunning }
    var isPlayerPlaying: Bool { player.isPlaying }

    // MARK: - Public API

    /// Enter deep state: rich 432 Hz bowl — warm, welcoming, celebratory.
    func playEnterDeep() {
        reverb.wetDryMix = 28
        scheduleBowl(fundamental: 432, decayRate: 0.8, duration: 4.0, amplitude: 0.10, attackDuration: 0.20)
        scheduleDuck(over: 4.5)
    }

    /// Exit deep state: 288 Hz (perfect fifth below 432 Hz) — lower, softer acknowledgement.
    func playExitDeep() {
        reverb.wetDryMix = 22
        scheduleBowl(fundamental: 288, decayRate: 1.4, duration: 2.5, amplitude: 0.08, attackDuration: 0.15)
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

    /// Deepening cue (B77): single soft 528 Hz bowl — gentle "going deeper" mark.
    /// Fires when within-deep ECDF display rises by ≥ 0.08 over a 30s rolling window.
    /// Quieter and shorter than enter-deep so it doesn't pull the user out of state.
    /// 528 Hz chosen to match the contact-restored bowl tonality (familiar, calming).
    func playDeepening() {
        reverb.wetDryMix = 24
        scheduleBowl(fundamental: 528, decayRate: 1.6, duration: 2.2, amplitude: 0.06, attackDuration: 0.25)
        scheduleDuck(over: 2.5)
    }

    /// Conditioning anchor: 7 Hz binaural theta tone (200 Hz L / 207 Hz R).
    /// Fires 20s into sustained deep state once per episode. The brain learns to associate
    /// this tone with the deep state — Pavlovian conditioning for faster future induction.
    /// Binaural effect requires headphones; without them it reduces to a faint mono tone.
    func playConditioningAnchor() {
        reverb.wetDryMix = 10
        scheduleBinauralPulse(carrierHz: 200.0, beatHz: 7.0, duration: 3.0, amplitude: 0.14)
        scheduleDuck(over: 3.5)
    }

    /// Beta wander cue: brief 1 kHz sine tick — fires when frontal beta spikes during shallow state.
    /// Trains metacognitive awareness without a jarring interrupt.
    func playBetaCue() {
        reverb.wetDryMix = 0
        scheduleSine(freq: 1000.0, duration: 0.25, amplitude: 0.07)
        // No duck — cue is soft enough and very brief
    }

    /// In-session guidance check-in: 396 Hz gentle bowl — soft reminder, non-disruptive.
    func playCheckIn() {
        reverb.wetDryMix = 20
        scheduleBowl(fundamental: 396, decayRate: 1.2, duration: 2.0, amplitude: 0.20)
        scheduleDuck(over: 2.5)
    }

    // MARK: - Session end gong (D)

    /// Session end gong: single sustained 432 Hz gong with 8-second fade-out.
    /// B83: fundamental raised from 84 Hz → 432 Hz. iPhone built-in speaker has known
    /// rolloff below ~200 Hz; the previous 84 Hz fundamental and lower partials were
    /// physically reproducible only via earbuds/AirPods. 432 Hz with inharmonic
    /// gong partials (1.516×, 2.871×, 4.465×, 6.122×) puts most energy in the
    /// 432-2645 Hz band — solidly within iPhone speaker passband.
    /// EndGongPlayer.shared.playSuccess() now invokes this only as a fallback when
    /// no `bowl_success.m4a` resource is bundled.
    /// Called from: EndGongPlayer fallback path; legacy callers retained for compatibility.
    func playGong() {
        Telemetry.audio.notice("ChimeEngine.playGong scheduled fundamental=432Hz")
        reverb.wetDryMix = 35
        scheduleGong(fundamental: 432, decayRate: 0.18, duration: 8.0, amplitude: 0.75)
        scheduleDuck(over: 8.0)
    }

    // MARK: - Alert chimes (B80: AlertCoordinator hooks)

    /// Session paused (BLE drop / interruption): two sharp descending tones — urgent, not alarming.
    /// 880 Hz → 660 Hz descending interval. Short (1.0s each) with minimal reverb.
    func playPauseChime() {
        reverb.wetDryMix = 8
        scheduleBowl(fundamental: 880, decayRate: 3.0, duration: 1.0, amplitude: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.reverb.wetDryMix = 8
            self?.scheduleBowl(fundamental: 660, decayRate: 3.0, duration: 1.0, amplitude: 0.28)
        }
        scheduleDuck(over: 2.0)
    }

    /// Session resumed: two ascending tones (inverse of pause) — reassuring resolution.
    /// 660 Hz → 880 Hz ascending. Mirrors pause chime for clear pairing.
    func playResumeChime() {
        reverb.wetDryMix = 18
        scheduleBowl(fundamental: 660, decayRate: 1.8, duration: 1.5, amplitude: 0.22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.reverb.wetDryMix = 18
            self?.scheduleBowl(fundamental: 880, decayRate: 1.8, duration: 1.8, amplitude: 0.28)
        }
        scheduleDuck(over: 3.0)
    }

    /// Session ended successfully: three long descending gong strikes — completion, finality.
    /// B83: fundamental raised 84 → 432 Hz (iPhone speaker passband).
    func playSuccessChime() {
        Telemetry.audio.notice("ChimeEngine.playSuccessChime scheduled fundamental=432Hz")
        reverb.wetDryMix = 32
        scheduleGong(fundamental: 432, decayRate: 0.20, duration: 6.0, amplitude: 0.50)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.scheduleGong(fundamental: 432, decayRate: 0.20, duration: 6.0, amplitude: 0.35)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.scheduleGong(fundamental: 432, decayRate: 0.20, duration: 6.0, amplitude: 0.22)
        }
        scheduleDuck(over: 11.0)
    }

    /// Session ended with failure (BLE timeout): rapid 5-pulse alert pattern — attention-grabbing.
    /// 800 Hz dry pings, 120ms apart. No duck (user needs maximum alertness).
    func playFailureChime() {
        reverb.wetDryMix = 2
        for i in 0..<5 {
            let delay = Double(i) * 0.14
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reverb.wetDryMix = 2
                self?.scheduleBowl(fundamental: 800, decayRate: 5.0, duration: 0.4, amplitude: 0.40)
            }
        }
    }

    /// Timer end: three descending gong strikes.
    /// B83: fundamental raised 84 → 432 Hz (iPhone speaker passband).
    func playTimerEnd() {
        Telemetry.audio.notice("ChimeEngine.playTimerEnd scheduled fundamental=432Hz")
        reverb.wetDryMix = 35
        scheduleGong(fundamental: 432, decayRate: 0.20, duration: 7.0, amplitude: 0.70)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.scheduleGong(fundamental: 432, decayRate: 0.20, duration: 7.0, amplitude: 0.50)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.scheduleGong(fundamental: 432, decayRate: 0.20, duration: 7.0, amplitude: 0.35)
        }
        scheduleDuck(over: 13.0)
    }

    // MARK: - Binaural pulse (pure sine stereo — two frequencies, no partials)

    private func scheduleBinauralPulse(carrierHz: Double, beatHz: Double,
                                        duration: Double, amplitude: Double) {
        guard let buf = stereoBuffer(duration: duration) else { return }
        let L = buf.floatChannelData![0]
        let R = buf.floatChannelData![1]
        let n = Int(buf.frameLength)
        let fadeSamples = Int(0.15 * sampleRate)  // 150ms fade in/out
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env: Double
            if i < fadeSamples        { env = Double(i) / Double(fadeSamples) }
            else if i > n - fadeSamples { env = Double(n - i) / Double(fadeSamples) }
            else                        { env = 1.0 }
            L[i] = Float(sin(2 * .pi * carrierHz           * t) * env * amplitude)
            R[i] = Float(sin(2 * .pi * (carrierHz + beatHz) * t) * env * amplitude)
        }
        schedule(buf)
    }

    // MARK: - Pure sine burst (for cue tones — no partial model)

    private func scheduleSine(freq: Double, duration: Double, amplitude: Double) {
        guard let buf = stereoBuffer(duration: duration) else { return }
        let L = buf.floatChannelData![0]
        let R = buf.floatChannelData![1]
        let n = Int(buf.frameLength)
        let fadeSamples = Int(min(0.02 * sampleRate, Double(n) / 4))  // 20ms fade
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env: Double
            if i < fadeSamples        { env = Double(i) / Double(fadeSamples) }
            else if i > n - fadeSamples { env = Double(n - i) / Double(fadeSamples) }
            else                        { env = 1.0 }
            let s = Float(sin(2 * .pi * freq * t) * env * amplitude)
            L[i] = s; R[i] = s
        }
        schedule(buf)
    }

    // MARK: - Bowl synthesis (stereo, per-partial decay, Haas)

    private func scheduleBowl(fundamental: Double, decayRate: Double, duration: Double,
                               amplitude: Double, attackDuration: Double = 0.025) {
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
        let attackSamples = Int(attackDuration * sampleRate)
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
        player.volume = chimeVolume
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
