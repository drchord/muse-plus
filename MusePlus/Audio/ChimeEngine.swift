import AVFoundation

final class ChimeEngine {
    static let shared = ChimeEngine()

    private let player     = AVAudioPlayerNode()
    private let sampleRate: Double = 44100

    init() {
        SharedAudioEngine.shared.addNode(player)
    }

    func playEnterDeep()    { play(fundamental: 432, decayRate: 0.9, duration: 3.5, amplitude: 0.35) }
    func playExitDeep()     { play(fundamental: 528, decayRate: 1.8, duration: 2.0, amplitude: 0.25) }
    func playContactLost()  { playGong(fundamental: 120, decayRate: 0.5, duration: 5.0, amplitude: 0.55) }

    // MARK: - Bowl bell

    private func play(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        guard let buffer = makeBuffer(duration: duration) else { return }
        let data = buffer.floatChannelData![0]
        let n    = Int(buffer.frameLength)

        let partials: [(ratio: Double, amp: Double)] = [
            (1.000, 1.00), (2.756, 0.45), (5.404, 0.20), (8.900, 0.08)
        ]
        for i in 0..<n {
            let t   = Double(i) / sampleRate
            let env = exp(-decayRate * t) * min(t / 0.025, 1.0)
            var s   = 0.0
            for p in partials { s += p.amp * sin(2 * .pi * fundamental * p.ratio * t) }
            data[i] = Float(s * env * amplitude)
        }
        schedule(buffer)
    }

    // MARK: - Gong

    private func playGong(fundamental: Double, decayRate: Double, duration: Double, amplitude: Double) {
        guard let buffer = makeBuffer(duration: duration) else { return }
        let data = buffer.floatChannelData![0]
        let n    = Int(buffer.frameLength)

        let partials: [(ratio: Double, amp: Double, decay: Double)] = [
            (1.000, 1.00, 0.40), (1.516, 0.70, 0.55),
            (2.871, 0.35, 0.80), (4.465, 0.18, 1.10), (6.122, 0.10, 1.50)
        ]
        for i in 0..<n {
            let t      = Double(i) / sampleRate
            let attack = min(t / 0.08, 1.0)
            var s      = 0.0
            for p in partials { s += p.amp * exp(-p.decay * decayRate * t) * sin(2 * .pi * fundamental * p.ratio * t) }
            data[i] = Float(s * attack * amplitude)
        }
        schedule(buffer)
    }

    // MARK: - Helpers

    private func makeBuffer(duration: Double) -> AVAudioPCMBuffer? {
        let n   = AVAudioFrameCount(sampleRate * duration)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        buf.frameLength = n
        return buf
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}
