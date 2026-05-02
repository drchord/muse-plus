import AVFoundation
import Accelerate

enum SoundLayer: String, CaseIterable, Identifiable {
    case brownNoise = "Brown Noise"
    case rain       = "Rain"
    case thunder    = "Thunder"
    case ocean      = "Ocean Waves"
    case wind       = "Wind"
    case brook      = "Brook"
    case forest     = "Forest"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .brownNoise: return "waveform"
        case .rain:       return "cloud.rain.fill"
        case .thunder:    return "cloud.bolt.fill"
        case .ocean:      return "water.waves"
        case .wind:       return "wind"
        case .brook:      return "drop.fill"
        case .forest:     return "leaf.fill"
        }
    }
}

final class SoundscapePlayer: ObservableObject {
    static let shared = SoundscapePlayer()

    @Published var activeLayers: Set<SoundLayer> = []
    @Published var layerVolumes: [SoundLayer: Float] = Dictionary(
        uniqueKeysWithValues: SoundLayer.allCases.map { ($0, 0.35) }
    )

    private let engine  = AVAudioEngine()
    private var nodes:   [SoundLayer: AVAudioPlayerNode] = [:]
    private var buffers: [SoundLayer: AVAudioPCMBuffer]  = [:]   // lazy cache

    private let sampleRate: Double = 44100
    private let bufferSecs: Double = 20

    init() {
        for layer in SoundLayer.allCases {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            nodes[layer] = node
        }
        try? engine.start()
    }

    func toggle(_ layer: SoundLayer) {
        if activeLayers.contains(layer) {
            deactivate(layer)
        } else {
            activate(layer)
        }
    }

    func setVolume(_ v: Float, for layer: SoundLayer) {
        layerVolumes[layer] = v
        nodes[layer]?.volume = v
    }

    // MARK: - Private

    private func activate(_ layer: SoundLayer) {
        activeLayers.insert(layer)
        let vol = layerVolumes[layer] ?? 0.35

        // Use cached buffer if available, else generate on background thread
        if let buf = buffers[layer] {
            startNode(nodes[layer]!, buffer: buf, volume: vol)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let buf = self.makeBuffer(layer)
                DispatchQueue.main.async {
                    self.buffers[layer] = buf
                    guard self.activeLayers.contains(layer),
                          let node = self.nodes[layer] else { return }
                    self.startNode(node, buffer: buf, volume: vol)
                }
            }
        }
    }

    private func deactivate(_ layer: SoundLayer) {
        activeLayers.remove(layer)
        nodes[layer]?.stop()
    }

    private func startNode(_ node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, volume: Float) {
        node.stop()
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        node.play()
    }

    // MARK: - Buffer synthesis

    private func makeBuffer(_ layer: SoundLayer) -> AVAudioPCMBuffer {
        let n   = AVAudioFrameCount(sampleRate * bufferSecs)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        switch layer {
        case .brownNoise: fillBrownNoise(buf)
        case .rain:       fillRain(buf)
        case .thunder:    fillThunder(buf)
        case .ocean:      fillOcean(buf)
        case .wind:       fillWind(buf)
        case .brook:      fillBrook(buf)
        case .forest:     fillForest(buf)
        }
        return buf
    }

    // MARK: Brown Noise

    private func fillBrownNoise(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            pL = 0.998 * pL + 0.018 * Float.random(in: -1...1)
            pR = 0.998 * pR + 0.018 * Float.random(in: -1...1)
            L[i] = pL; R[i] = pR
        }
        normalize(L, R, n: n, target: 0.70)
    }

    // MARK: Rain

    private func fillRain(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            L[i] = wL - 0.92 * pL
            R[i] = wR - 0.92 * pR
            pL = wL; pR = wR
        }
        // Scattered drip pulses
        for _ in 0..<Int(bufferSecs * 110) {
            let pos = Int.random(in: 0..<(n - 100))
            let amp = Float.random(in: 0.15...0.55)
            let dur = Int.random(in: 20...90)
            let ch  = Bool.random() ? L : R
            for j in 0..<min(dur, n - pos) {
                ch[pos + j] += amp * expf(-Float(j) * 0.09)
            }
        }
        normalize(L, R, n: n, target: 0.65)
    }

    // MARK: Thunder  (low rumble + periodic cracks)

    private func fillThunder(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]

        // Rumble: very-low brown noise
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            pL = 0.9995 * pL + 0.008 * Float.random(in: -1...1)
            pR = 0.9995 * pR + 0.008 * Float.random(in: -1...1)
            let t = Double(i) / sampleRate
            let rumbleAmp = Float(0.4 + 0.6 * abs(sin(2 * .pi * 0.031 * t)))
            L[i] = pL * rumbleAmp
            R[i] = pR * rumbleAmp
        }

        // Thunder cracks — 2-4 per buffer
        let crackCount = Int.random(in: 2...4)
        for _ in 0..<crackCount {
            let onset  = Int.random(in: Int(sampleRate * 3)...(n - Int(sampleRate * 5)))
            let crackDur = Int(sampleRate * 0.15)
            let trailDur = Int(sampleRate * Double.random(in: 3...6))
            let amp = Float.random(in: 0.5...0.85)
            // Sharp crack
            for j in 0..<min(crackDur, n - onset) {
                let env = expf(-Float(j) * 0.06) * Float(min(j, 5)) / 5.0
                L[onset + j] += Float.random(in: -1...1) * amp * env
                R[onset + j] += Float.random(in: -1...1) * amp * env
            }
            // Rolling rumble trail
            var trail: Float = 0
            for j in 0..<min(trailDur, n - (onset + crackDur)) {
                trail = 0.999 * trail + 0.005 * Float.random(in: -1...1)
                let env = expf(-Float(j) / Float(sampleRate) * 1.2)
                L[onset + crackDur + j] += trail * env * amp * 0.6
                R[onset + crackDur + j] += trail * env * amp * 0.6
            }
        }
        normalize(L, R, n: n, target: 0.75)
    }

    // MARK: Ocean Waves

    private func fillOcean(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            pL = 0.997 * pL + 0.014 * Float.random(in: -1...1)
            pR = 0.997 * pR + 0.014 * Float.random(in: -1...1)
            let t = Double(i) / sampleRate
            let wL = Float(0.25 + 0.75 * pow(max(0, sin(2 * .pi * 0.083 * t)), 1.8))
            let wR = Float(0.25 + 0.75 * pow(max(0, sin(2 * .pi * 0.067 * t + 1.3)), 1.8))
            L[i] = pL * wL
            R[i] = pR * wR
        }
        normalize(L, R, n: n, target: 0.75)
    }

    // MARK: Wind

    private func fillWind(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var lp1L: Float = 0, lp2L: Float = 0
        var lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t  = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.94 * lp1L + 0.06 * wL; lp2L = 0.985 * lp2L + 0.015 * wL
            lp1R = 0.94 * lp1R + 0.06 * wR; lp2R = 0.985 * lp2R + 0.015 * wR
            // Slow gusts: two overlapping sine LFOs
            let gust = Float(0.4 + 0.4 * sin(2 * .pi * 0.041 * t)
                           + 0.2 * sin(2 * .pi * 0.013 * t + 1.7))
            L[i] = (lp1L - lp2L) * gust * 14.0
            R[i] = (lp1R - lp2R) * gust * 14.0
        }
        normalize(L, R, n: n, target: 0.65)
    }

    // MARK: Brook  (tumbling water over rocks)

    private func fillBrook(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        // Mid-frequency bandpass (200–1500 Hz region) + turbulence modulation
        var lp1L: Float = 0, lp2L: Float = 0
        var lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t  = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.88 * lp1L + 0.12 * wL; lp2L = 0.97 * lp2L + 0.03 * wL
            lp1R = 0.88 * lp1R + 0.12 * wR; lp2R = 0.97 * lp2R + 0.03 * wR
            // Turbulence: fast irregular modulation simulating water over rocks
            let turb = Float(0.55 + 0.35 * sin(2 * .pi * 1.7 * t)
                           + 0.10 * sin(2 * .pi * 3.1 * t + 0.9))
            L[i] = (lp1L - lp2L) * turb * 9.0
            R[i] = (lp1R - lp2R) * turb * 9.0
        }
        // Add high-frequency sparkle (water splashes)
        for _ in 0..<Int(bufferSecs * 40) {
            let pos = Int.random(in: 0..<(n - 60))
            let amp = Float.random(in: 0.05...0.18)
            let dur = Int.random(in: 15...50)
            let ch  = Bool.random() ? L : R
            for j in 0..<min(dur, n - pos) {
                ch[pos + j] += Float.random(in: -1...1) * amp * expf(-Float(j) * 0.12)
            }
        }
        normalize(L, R, n: n, target: 0.68)
    }

    // MARK: Forest  (wind + birdsong)

    private func fillForest(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var lp1L: Float = 0, lp2L: Float = 0
        var lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t  = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.96 * lp1L + 0.04 * wL; lp2L = 0.99 * lp2L + 0.01 * wL
            lp1R = 0.96 * lp1R + 0.04 * wR; lp2R = 0.99 * lp2R + 0.01 * wR
            let windAmp = Float(0.5 + 0.5 * sin(2 * .pi * 0.036 * t
                                              + 0.8 * sin(2 * .pi * 0.011 * t)))
            L[i] = (lp1L - lp2L) * windAmp * 12.0
            R[i] = (lp1R - lp2R) * windAmp * 12.0
        }
        // Bird chirps
        for _ in 0..<Int(bufferSecs * 0.9) {
            let onset = Int.random(in: 0..<max(1, n - Int(sampleRate / 2)))
            let dur   = Int.random(in: Int(sampleRate * 0.12)...Int(sampleRate * 0.38))
            let f0    = Double.random(in: 2000...5500)
            let f1    = Double.random(in: 1500...6500)
            let amp   = Float.random(in: 0.08...0.22)
            let ch    = Bool.random() ? L : R
            for j in 0..<min(dur, n - onset) {
                let ph   = Double(j) / Double(dur)
                let env  = sin(.pi * ph)
                let freq = f0 + (f1 - f0) * ph
                ch[onset + j] += Float(env * Double(amp) * sin(2 * .pi * freq * Double(j) / sampleRate))
            }
        }
        normalize(L, R, n: n, target: 0.70)
    }

    // MARK: Helpers

    private func normalize(_ L: UnsafeMutablePointer<Float>,
                           _ R: UnsafeMutablePointer<Float>,
                           n: Int, target: Float) {
        var pL: Float = 0, pR: Float = 0
        vDSP_maxmgv(L, 1, &pL, vDSP_Length(n))
        vDSP_maxmgv(R, 1, &pR, vDSP_Length(n))
        let peak = max(pL, pR, 1e-6)
        var scale = target / peak
        vDSP_vsmul(L, 1, &scale, L, 1, vDSP_Length(n))
        vDSP_vsmul(R, 1, &scale, R, 1, vDSP_Length(n))
    }
}
