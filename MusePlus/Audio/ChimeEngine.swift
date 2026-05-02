import AVFoundation

final class ChimeEngine {
    static let shared = ChimeEngine()

    private let engine     = AVAudioEngine()
    private let player     = AVAudioPlayerNode()
    private let sampleRate: Double = 44100

    init() {
        // Explicit mono format — prevents format mismatch after route changes
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        configureSession()
        try? engine.start()
        observeAudio()
    }

    func playEnterDeep()   { play(fundamental: 432, decayRate: 0.9, duration: 3.5, amplitude: 0.35) }
    func playExitDeep()    { play(fundamental: 528, decayRate: 1.8, duration: 2.0, amplitude: 0.25) }
    func playContactLost() { playGong(fundamental: 120, decayRate: 0.5, duration: 5.0, amplitude: 0.55) }

    // MARK: - Bowl bell

    private func play(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        guard let buf = monoBuffer(duration: duration) else { return }
        let data = buf.floatChannelData![0]
        let n    = Int(buf.frameLength)
        let partials: [(Double, Double)] = [(1.0, 1.0), (2.756, 0.45), (5.404, 0.2), (8.9, 0.08)]
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let e = exp(-decayRate * t) * min(t / 0.025, 1.0)
            var s = 0.0
            for (r, a) in partials { s += a * sin(2 * .pi * fundamental * r * t) }
            data[i] = Float(s * e * amplitude)
        }
        schedule(buf)
    }

    // MARK: - Gong

    private func playGong(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        guard let buf = monoBuffer(duration: duration) else { return }
        let data = buf.floatChannelData![0]
        let n    = Int(buf.frameLength)
        let partials: [(Double, Double, Double)] = [
            (1.0, 1.0, 0.4), (1.516, 0.7, 0.55), (2.871, 0.35, 0.8), (4.465, 0.18, 1.1), (6.122, 0.1, 1.5)
        ]
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let a = min(t / 0.08, 1.0)
            var s = 0.0
            for (r, amp, d) in partials { s += amp * exp(-d * decayRate * t) * sin(2 * .pi * fundamental * r * t) }
            data[i] = Float(s * a * amplitude)
        }
        schedule(buf)
    }

    // MARK: - Helpers

    private func monoBuffer(duration: Double) -> AVAudioPCMBuffer? {
        let n   = AVAudioFrameCount(sampleRate * duration)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)
        buf?.frameLength = n
        return buf
    }

    private func schedule(_ buf: AVAudioPCMBuffer) {
        ensureRunning()
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buf, completionHandler: nil)
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
            // Delay lets iOS finish the route-change before we restart
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
