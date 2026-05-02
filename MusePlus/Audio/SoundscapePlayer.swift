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
        case .brownNoise: "waveform"
        case .rain:       "cloud.rain.fill"
        case .thunder:    "cloud.bolt.fill"
        case .ocean:      "water.waves"
        case .wind:       "wind"
        case .brook:      "drop.fill"
        case .forest:     "leaf.fill"
        case .birds:      "bird.fill"
        case .binaural:   "headphones"
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
}

// MARK: - Player

final class SoundscapePlayer: ObservableObject {
    static let shared = SoundscapePlayer()

    @Published var activeLayers:   Set<SoundLayer>     = []
    @Published var layerVolumes:   [SoundLayer: Float] = Dictionary(
        uniqueKeysWithValues: SoundLayer.allCases.map { ($0, 0.35) })
    @Published var binauralPreset: BinauralPreset      = .theta {
        didSet {
            guard activeLayers.contains(.binaural) else { return }
            buffers.removeValue(forKey: .binaural)
            nodes[.binaural]?.stop()
            startLayer(.binaural)
        }
    }

    private let engine = AVAudioEngine()
    private var nodes:   [SoundLayer: AVAudioPlayerNode] = [:]
    private var buffers: [SoundLayer: AVAudioPCMBuffer]  = [:]
    private let sampleRate: Double = 44100
    private let bufferSecs: Double = 20

    init() {
        // Attach ALL nodes before engine starts
        for layer in SoundLayer.allCases {
            let node = AVAudioPlayerNode()
            nodes[layer] = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
        }
        configureSession()
        try? engine.start()
        observeAudio()
    }

    // MARK: - Public

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
            startNode(nodes[layer]!, buffer: buf)
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
                node.volume = vol
                self.startNode(node, buffer: buf)
            }
        }
    }

    private func deactivate(_ layer: SoundLayer) {
        activeLayers.remove(layer)
        nodes[layer]?.stop()
    }

    private func startNode(_ node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) {
        node.stop()
        ensureRunning()
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        node.play()
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
            guard let self else { return }
            self.ensureRunning()
            // Restart active layers after engine recovers
            let active = self.activeLayers
            for layer in active {
                guard let node = self.nodes[layer],
                      let buf  = self.buffers[layer] else { continue }
                node.stop()
                node.scheduleBuffer(buf, at: nil, options: .loops)
                node.play()
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

    // MARK: - Buffer factory

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
        norm(L, R, n: n, t: 0.70)
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
            let amp = Float.random(in: 0.15...0.55), dur = Int.random(in: 20...90)
            let ch  = Bool.random() ? L : R
            for j in 0..<min(dur, n - pos) { ch[pos + j] += amp * expf(-Float(j) * 0.09) }
        }
        norm(L, R, n: n, t: 0.65)
    }

    // MARK: - Thunder

    private func fillThunder(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var lp1L: Float = 0, lp2L: Float = 0, lp1R: Float = 0, lp2R: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lp1L = 0.979 * lp1L + 0.021 * wL; lp2L = 0.9957 * lp2L + 0.0043 * wL
            lp1R = 0.979 * lp1R + 0.021 * wR; lp2R = 0.9957 * lp2R + 0.0043 * wR
            let mod = Float(0.5 + 0.5 * abs(sin(2 * .pi * 0.04 * t)))
            L[i] = (lp1L - lp2L) * mod * 16.0
            R[i] = (lp1R - lp2R) * mod * 16.0
        }
        norm(L, R, n: n, t: 0.22)
        let cracks = Int.random(in: 2...4)
        for _ in 0..<cracks {
            guard n > Int(sampleRate * 8) else { break }
            let o = Int.random(in: Int(sampleRate * 2)...(n - Int(sampleRate * 4)))
            let cd = Int(sampleRate * 0.12), td = Int(sampleRate * Double.random(in: 2...4))
            let amp = Float.random(in: 0.40...0.60)
            for j in 0..<min(cd, n - o) {
                let e = min(Float(j) / 5.0, 1.0) * expf(-Float(j) * 0.055)
                L[o+j] += Float.random(in: -1...1) * e * amp
                R[o+j] += Float.random(in: -1...1) * e * amp
            }
            var tr: Float = 0
            for j in 0..<min(td, n - (o + cd)) {
                tr = 0.986 * tr + 0.014 * Float.random(in: -1...1)
                let e = expf(-Float(j) / Float(sampleRate) * 1.4)
                L[o+cd+j] += tr * e * amp * 0.65
                R[o+cd+j] += tr * e * amp * 0.65
            }
        }
        norm(L, R, n: n, t: 0.72)
    }

    // MARK: - Ocean

    private func fillOcean(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var pL: Float = 0, pR: Float = 0
        for i in 0..<n {
            pL = 0.997 * pL + 0.014 * Float.random(in: -1...1)
            pR = 0.997 * pR + 0.014 * Float.random(in: -1...1)
            let t = Double(i) / sampleRate
            L[i] = pL * Float(0.25 + 0.75 * pow(max(0, sin(2 * .pi * 0.083 * t)), 1.8))
            R[i] = pR * Float(0.25 + 0.75 * pow(max(0, sin(2 * .pi * 0.067 * t + 1.3)), 1.8))
        }
        norm(L, R, n: n, t: 0.75)
    }

    // MARK: - Wind

    private func fillWind(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var a1L: Float=0, a2L: Float=0, a1R: Float=0, a2R: Float=0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            a1L = 0.94*a1L + 0.06*wL; a2L = 0.985*a2L + 0.015*wL
            a1R = 0.94*a1R + 0.06*wR; a2R = 0.985*a2R + 0.015*wR
            let g = Float(0.4 + 0.4 * sin(2 * .pi * 0.041 * t) + 0.2 * sin(2 * .pi * 0.013 * t + 1.7))
            L[i] = (a1L - a2L) * g * 14.0
            R[i] = (a1R - a2R) * g * 14.0
        }
        norm(L, R, n: n, t: 0.65)
    }

    // MARK: - Brook

    private func fillBrook(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var a1L: Float=0, a2L: Float=0, a1R: Float=0, a2R: Float=0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            a1L = 0.88*a1L + 0.12*wL; a2L = 0.97*a2L + 0.03*wL
            a1R = 0.88*a1R + 0.12*wR; a2R = 0.97*a2R + 0.03*wR
            let m = Float(0.55 + 0.35 * sin(2 * .pi * 1.7 * t) + 0.10 * sin(2 * .pi * 3.1 * t + 0.9))
            L[i] = (a1L - a2L) * m * 9.0
            R[i] = (a1R - a2R) * m * 9.0
        }
        for _ in 0..<Int(bufferSecs * 40) {
            let pos = Int.random(in: 0..<(n - 60))
            let amp = Float.random(in: 0.05...0.18), dur = Int.random(in: 15...50)
            let ch  = Bool.random() ? L : R
            for j in 0..<min(dur, n - pos) { ch[pos+j] += Float.random(in: -1...1) * amp * expf(-Float(j) * 0.12) }
        }
        norm(L, R, n: n, t: 0.68)
    }

    // MARK: - Forest

    private func fillForest(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var a1L: Float=0, a2L: Float=0, a1R: Float=0, a2R: Float=0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            a1L = 0.96*a1L + 0.04*wL; a2L = 0.99*a2L + 0.01*wL
            a1R = 0.96*a1R + 0.04*wR; a2R = 0.99*a2R + 0.01*wR
            let m = Float(0.5 + 0.5 * sin(2 * .pi * 0.036 * t + 0.8 * sin(2 * .pi * 0.011 * t)))
            L[i] = (a1L - a2L) * m * 12.0
            R[i] = (a1R - a2R) * m * 12.0
        }
        chirps(L, R, n: n, count: Int(bufferSecs * 0.9))
        norm(L, R, n: n, t: 0.70)
    }

    // MARK: - Birds

    private func fillBirds(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        for i in 0..<n { L[i] = 0; R[i] = 0 }
        chirps(L, R, n: n, count: Int(bufferSecs * 2.5), fLo: 1500, fHi: 4000, amp: 0.20...0.45)
        chirps(L, R, n: n, count: Int(bufferSecs * 1.8), fLo: 3500, fHi: 7000, amp: 0.15...0.35)
        chirps(L, R, n: n, count: Int(bufferSecs * 1.2), fLo: 6000, fHi: 9000, amp: 0.10...0.25)
        norm(L, R, n: n, t: 0.70)
    }

    // MARK: - Binaural Beats

    private func fillBinaural(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        let carrier = 200.0, beat = binauralPreset.beatHz
        for i in 0..<n {
            let t = Double(i) / sampleRate
            L[i] = Float(sin(2 * .pi * carrier         * t)) * 0.45
            R[i] = Float(sin(2 * .pi * (carrier + beat) * t)) * 0.45
        }
    }

    // MARK: - Shared helpers

    private func chirps(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>,
                        n: Int, count: Int,
                        fLo: Double = 2000, fHi: Double = 5500,
                        amp: ClosedRange<Float> = 0.08...0.22) {
        for _ in 0..<count {
            let maxO = max(1, n - Int(sampleRate * 0.5))
            let o    = Int.random(in: 0..<maxO)
            let dur  = Int.random(in: Int(sampleRate * 0.12)...Int(sampleRate * 0.40))
            let f0   = Double.random(in: fLo...fHi), f1 = Double.random(in: fLo...fHi)
            let a    = Float.random(in: amp)
            let ch   = Bool.random() ? L : R
            for j in 0..<min(dur, n - o) {
                let ph = Double(j) / Double(dur)
                ch[o+j] += Float(sin(.pi * ph) * Double(a) * sin(2 * .pi * (f0 + (f1-f0)*ph) * Double(j) / sampleRate))
            }
        }
    }

    private func norm(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>,
                      n: Int, t: Float) {
        var pL: Float = 0, pR: Float = 0
        vDSP_maxmgv(L, 1, &pL, vDSP_Length(n))
        vDSP_maxmgv(R, 1, &pR, vDSP_Length(n))
        var s = t / max(pL, pR, 1e-6)
        vDSP_vsmul(L, 1, &s, L, 1, vDSP_Length(n))
        vDSP_vsmul(R, 1, &s, R, 1, vDSP_Length(n))
    }
}
