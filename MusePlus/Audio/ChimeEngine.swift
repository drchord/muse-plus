import AVFoundation

final class ChimeEngine {
    static let shared = ChimeEngine()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44100

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        configureSession()
        try? engine.start()
    }

    // Warm descending bowl — signals you crossed INTO deep state
    func playEnterDeep() {
        play(fundamental: 432, decayRate: 0.9, duration: 3.5, amplitude: 0.35)
    }

    // Lighter ascending tone — signals you drifted OUT of deep state
    func playExitDeep() {
        play(fundamental: 528, decayRate: 1.8, duration: 2.0, amplitude: 0.25)
    }

    // Deep gong — any electrode loses contact
    func playContactLost() {
        playGong(fundamental: 120, decayRate: 0.5, duration: 5.0, amplitude: 0.55)
    }

    // MARK: - Private

    private func playGong(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        // Gong: slow attack, low fundamental, heavily inharmonic partials
        let partials: [(ratio: Double, amp: Double, decay: Double)] = [
            (1.000, 1.00, 0.40),
            (1.516, 0.70, 0.55),
            (2.871, 0.35, 0.80),
            (4.465, 0.18, 1.10),
            (6.122, 0.10, 1.50),
        ]
        let attackDuration = 0.08   // 80ms boom onset

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let attack = min(t / attackDuration, 1.0)
            var sample = 0.0
            for p in partials {
                let env = exp(-p.decay * decayRate * t)
                sample += p.amp * env * sin(2 * .pi * fundamental * p.ratio * t)
            }
            data[i] = Float(sample * attack * amplitude)
        }

        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func play(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]

        // Tibetan singing bowl partial ratios and relative amplitudes
        let partials: [(ratio: Double, amp: Double)] = [
            (1.000, 1.00),
            (2.756, 0.45),
            (5.404, 0.20),
            (8.900, 0.08),
        ]

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-decayRate * t)
            let attack   = min(t / 0.025, 1.0)   // 25 ms soft onset
            var sample   = 0.0
            for p in partials {
                sample += p.amp * sin(2 * .pi * fundamental * p.ratio * t)
            }
            data[i] = Float(sample * envelope * attack * amplitude)
        }

        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }
}
