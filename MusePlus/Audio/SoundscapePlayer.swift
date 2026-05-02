import AVFoundation
import Accelerate

// MARK: - Enums

enum SoundLayer: String, CaseIterable, Identifiable {
    case brownNoise = "Brown Noise"
    case rain       = "Rain"
    case thunder    = "Thunder"
    case ocean      = "Ocean Waves"
    case wind       = "Wind"
    case brook      = "Brook"
    case forest     = "Forest"
    case birds      = "Birds"
    case binaural   = "Binaural Beats"

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
        case .birds:      return "bird.fill"
        case .binaural:   return "headphones"
        }
    }
}

enum BinauralPreset: String, CaseIterable, Identifiable {
    case delta = "Delta 2 Hz — deep sleep threshold"
    case theta = "Theta 6 Hz — deep meditation"
    case alpha = "Alpha 10 Hz — relaxed focus"
    case beta  = "Beta 20 Hz — alert clarity"

    var id: String { rawValue }
    var beatHz: Double {
        switch self { case .delta: 2; case .theta: 6; case .alpha: 10; case .beta: 20 }
    }
    var label: String { rawValue }
}

// MARK: - SoundscapePlayer

final class SoundscapePlayer: ObservableObject {
    static let shared = SoundscapePlayer()

    @Published var activeLayers:  Set<SoundLayer>         = []
    @Published var layerVolumes:  [SoundLayer: Float]     = Dictionary(
        uniqueKeysWithValues: SoundLayer.allCases.map { ($0, 0.35) })
    @Published var binauralPreset: BinauralPreset = .theta {
        didSet {
            guard activeLayers.contains(.binaural) else { return }
            buffers.removeValue(forKey: .binaural)
            nodes[.binaural]?.stop()
            startLayer(.binaural)
        }
    }

    private var nodes:   [SoundLayer: AVAudioPlayerNode]  = [:]
    private var buffers: [SoundLayer: AVAudioPCMBuffer]   = [:]

    private let sampleRate: Double = 44100
    private let bufferSecs: Double = 20

    init() {
        for layer in SoundLayer.allCases {
            let node = AVAudioPlayerNode()
            nodes[layer] = node
            SharedAudioEngine.shared.addNode(node)
        }
    }

    // MARK: - Public API

    func toggle(_ layer: SoundLayer) {
        activeLayers.contains(layer) ? deactivate(layer) : activate(layer)
    }

    func setVolume(_ v: Float, for layer: SoundLayer) {
        layerVolumes[layer] = v
        nodes[layer]?.volume = v
    }

    // MARK: - Internal

    private func activate(_ layer: SoundLayer) {
        activeLayers.insert(layer)
        if let buf = buffers[layer] {
            startNode(nodes[layer]!, buffer: buf, volume: layerVolumes[layer] ?? 0.35)
        } else {
            startLayer(layer)
        }
    }

    private func startLayer(_ layer: SoundLayer) {
        let vol = layerVolumes[layer] ?? 0.35
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

    private func deactivate(_ layer: SoundLayer) {
        activeLayers.remove(layer)
        nodes[layer]?.stop()
    }

    private func startNode(_ node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, volume: Float) {
        node.stop()
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        if !SharedAudioEngine.shared.engine.isRunning {
            SharedAudioEngine.shared.restart()
        }
        node.play()
    }

    // MARK: - Buffer dispatch

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
        case .birds:      fillBirds(buf)
        case .binaural:   fillBinaural(buf)
        }
        return buf
    }

    // MARK: - Brown Noise

    private func fillBrownNoise(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            pL = 0.998 * pL + 0.018 * .random(in: -1...1)
            pR = 0.998 * pR + 0.018 * .random(in: -1...1)
            L[i] = pL; R[i] = pR
        }
        normalize(L, R, n: n, target: 0.70)
    }

    // MARK: - Rain

    private func fillRain(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            L[i] = wL - 0.92 * pL; R[i] = wR - 0.92 * pR
            pL = wL; pR = wR
        }
        for _ in 0..<Int(bufferSecs * 110) {
            let pos = Int.random(in: 0..<(n - 100))
            let amp = Float.random(in: 0.15...0.55)
            let dur = Int.random(in: 20...90)
            let ch  = Bool.random() ? L : R
            for j in 0..<min(dur, n - pos) { ch[pos + j] += amp * expf(-Float(j) * 0.09) }
        }
        normalize(L, R, n: n, target: 0.65)
    }

    // MARK: - Thunder  (fixed: audible bass rumble + transient cracks)

    private func fillThunder(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]

        // Bandpass ~30-150 Hz using two cascaded low-pass filters
        var lp1L: Float = 0, lp2L: Float = 0
        var lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.979 * lp1L + 0.021 * wL   // ~150 Hz cutoff
            lp1R = 0.979 * lp1R + 0.021 * wR
            lp2L = 0.9957 * lp2L + 0.0043 * wL  // ~30 Hz cutoff
            lp2R = 0.9957 * lp2R + 0.0043 * wR
            let mod = Float(0.5 + 0.5 * abs(sin(2 * .pi * 0.04 * t)))
            L[i] = (lp1L - lp2L) * mod * 16.0
            R[i] = (lp1R - lp2R) * mod * 16.0
        }
        normalize(L, R, n: n, target: 0.22)   // quiet rumble baseline

        // Thunder cracks on top — 2-4 per buffer
        let crackCount = Int.random(in: 2...4)
        for _ in 0..<crackCount {
            guard n > Int(sampleRate * 8) else { break }
            let onset    = Int.random(in: Int(sampleRate * 2)...(n - Int(sampleRate * 4)))
            let crackDur = Int(sampleRate * 0.12)
            let trailDur = Int(sampleRate * Double.random(in: 2.0...4.0))
            let amp      = Float.random(in: 0.40...0.60)

            for j in 0..<min(crackDur, n - onset) {
                let env = min(Float(j) / 5.0, 1.0) * expf(-Float(j) * 0.055)
                L[onset + j] += Float.random(in: -1...1) * env * amp
                R[onset + j] += Float.random(in: -1...1) * env * amp
            }
            var trail: Float = 0
            for j in 0..<min(trailDur, n - (onset + crackDur)) {
                trail = 0.986 * trail + 0.014 * Float.random(in: -1...1)
                let env = expf(-Float(j) / Float(sampleRate) * 1.4)
                L[onset + crackDur + j] += trail * env * amp * 0.65
                R[onset + crackDur + j] += trail * env * amp * 0.65
            }
        }
        normalize(L, R, n: n, target: 0.72)
    }

    // MARK: - Ocean Waves

    private func fillOcean(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            pL = 0.997 * pL + 0.014 * Float.random(in: -1...1)
            pR = 0.997 * pR + 0.014 * Float.random(in: -1...1)
            let t  = Double(i) / sampleRate
            let wL = Float(0.25 + 0.75 * pow(max(0, sin(2 * .pi * 0.083 * t)), 1.8))
            let wR = Float(0.25 + 0.75 * pow(max(0, sin(2 * .pi * 0.067 * t + 1.3)), 1.8))
            L[i] = pL * wL; R[i] = pR * wR
        }
        normalize(L, R, n: n, target: 0.75)
    }

    // MARK: - Wind

    private func fillWind(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var lp1L: Float = 0, lp2L: Float = 0
        var lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.94 * lp1L + 0.06 * wL; lp2L = 0.985 * lp2L + 0.015 * wL
            lp1R = 0.94 * lp1R + 0.06 * wR; lp2R = 0.985 * lp2R + 0.015 * wR
            let gust = Float(0.4 + 0.4 * sin(2 * .pi * 0.041 * t) + 0.2 * sin(2 * .pi * 0.013 * t + 1.7))
            L[i] = (lp1L - lp2L) * gust * 14.0
            R[i] = (lp1R - lp2R) * gust * 14.0
        }
        normalize(L, R, n: n, target: 0.65)
    }

    // MARK: - Brook

    private func fillBrook(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var lp1L: Float = 0, lp2L: Float = 0
        var lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.88 * lp1L + 0.12 * wL; lp2L = 0.97 * lp2L + 0.03 * wL
            lp1R = 0.88 * lp1R + 0.12 * wR; lp2R = 0.97 * lp2R + 0.03 * wR
            let turb = Float(0.55 + 0.35 * sin(2 * .pi * 1.7 * t) + 0.10 * sin(2 * .pi * 3.1 * t + 0.9))
            L[i] = (lp1L - lp2L) * turb * 9.0
            R[i] = (lp1R - lp2R) * turb * 9.0
        }
        for _ in 0..<Int(bufferSecs * 40) {
            let pos = Int.random(in: 0..<(n - 60))
            let amp = Float.random(in: 0.05...0.18)
            let dur = Int.random(in: 15...50)
            let ch  = Bool.random() ? L : R
            for j in 0..<min(dur, n - pos) { ch[pos + j] += Float.random(in: -1...1) * amp * expf(-Float(j) * 0.12) }
        }
        normalize(L, R, n: n, target: 0.68)
    }

    // MARK: - Forest (wind + birds)

    private func fillForest(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var lp1L: Float = 0, lp2L: Float = 0
        var lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.96 * lp1L + 0.04 * wL; lp2L = 0.99 * lp2L + 0.01 * wL
            lp1R = 0.96 * lp1R + 0.04 * wR; lp2R = 0.99 * lp2R + 0.01 * wR
            let windAmp = Float(0.5 + 0.5 * sin(2 * .pi * 0.036 * t + 0.8 * sin(2 * .pi * 0.011 * t)))
            L[i] = (lp1L - lp2L) * windAmp * 12.0
            R[i] = (lp1R - lp2R) * windAmp * 12.0
        }
        addChirps(L: L, R: R, n: n, count: Int(bufferSecs * 0.9), ampRange: 0.08...0.22)
        normalize(L, R, n: n, target: 0.70)
    }

    // MARK: - Birds (chirps only, no wind)

    private func fillBirds(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        // Silent base — only chirps
        for i in 0..<n { L[i] = 0; R[i] = 0 }
        // Denser chirping, multiple frequency ranges simulating different species
        addChirps(L: L, R: R, n: n, count: Int(bufferSecs * 2.5),
                  freqRange: 1500...4000, ampRange: 0.20...0.45)   // low birds
        addChirps(L: L, R: R, n: n, count: Int(bufferSecs * 1.8),
                  freqRange: 3500...7000, ampRange: 0.15...0.35)   // high birds
        addChirps(L: L, R: R, n: n, count: Int(bufferSecs * 1.2),
                  freqRange: 6000...9000, ampRange: 0.10...0.25)   // distant thin calls
        normalize(L, R, n: n, target: 0.70)
    }

    // MARK: - Binaural Beats  (seamless loop: carrier × bufferSecs = integer)

    private func fillBinaural(_ buf: AVAudioPCMBuffer) {
        let n        = Int(buf.frameLength)
        let L        = buf.floatChannelData![0], R = buf.floatChannelData![1]
        let carrier  = 200.0                           // Hz — left ear
        let beat     = binauralPreset.beatHz           // Hz — difference
        for i in 0..<n {
            let t = Double(i) / sampleRate
            L[i] = Float(sin(2 * .pi * carrier       * t)) * 0.45
            R[i] = Float(sin(2 * .pi * (carrier + beat) * t)) * 0.45
        }
        // No normalization — amplitude is fixed for binaural effect consistency
    }

    // MARK: - Shared chirp helper

    private func addChirps(L: UnsafeMutablePointer<Float>,
                           R: UnsafeMutablePointer<Float>,
                           n: Int,
                           count: Int,
                           freqRange: ClosedRange<Double> = 2000...5500,
                           ampRange:  ClosedRange<Float>  = 0.08...0.22) {
        let n = n
        for _ in 0..<count {
            let maxOnset = max(1, n - Int(sampleRate * 0.5))
            let onset = Int.random(in: 0..<maxOnset)
            let dur   = Int.random(in: Int(sampleRate * 0.12)...Int(sampleRate * 0.40))
            let f0    = Double.random(in: freqRange)
            let f1    = Double.random(in: freqRange)
            let amp   = Float.random(in: ampRange)
            let ch    = Bool.random() ? L : R
            for j in 0..<min(dur, n - onset) {
                let ph   = Double(j) / Double(dur)
                let env  = sin(.pi * ph)
                let freq = f0 + (f1 - f0) * ph
                ch[onset + j] += Float(env * Double(amp) * sin(2 * .pi * freq * Double(j) / sampleRate))
            }
        }
    }

    // MARK: - Normalize

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
