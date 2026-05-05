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
    // Layers that load from bundled M4A files vs DSP-generated
    var isFileBased: Bool {
        switch self {
        case .brownNoise, .binaural: return false
        default: return true
        }
    }
    var fileName: String { rawValue.lowercased().replacingOccurrences(of: " ", with: "_").components(separatedBy: "_waves").first ?? rawValue.lowercased() }
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
            customBinauralHz = nil
            buffers.removeValue(forKey: .binaural)
            nodes[.binaural]?.stop()
            startLayer(.binaural)
        }
    }

    // Adaptive binaural: set by updateAdaptiveDepth; nil = use binauralPreset
    var customBinauralHz: Double? = nil

    private let engine = AVAudioEngine()
    private var nodes:   [SoundLayer: AVAudioPlayerNode] = [:]
    private var buffers: [SoundLayer: AVAudioPCMBuffer]  = [:]
    private let sampleRate: Double = 44100
    private let bufferSecs: Double = 20   // DSP layers only

    // Volume ducking state
    private var unduckTimer: DispatchWorkItem?

    init() {
        // Explicit stereo format — prevents crash after BT route change
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        for layer in SoundLayer.allCases {
            let node = AVAudioPlayerNode()
            nodes[layer] = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
        }
        configureSession()
        try? engine.start()
        observeAudio()
    }

    // MARK: - Public API

    func toggle(_ layer: SoundLayer) {
        activeLayers.contains(layer) ? deactivate(layer) : activate(layer)
    }

    func setVolume(_ v: Float, for layer: SoundLayer) {
        layerVolumes[layer] = v
        guard !isDucked else { return }
        nodes[layer]?.volume = v
    }

    /// Fade all active layers to silence, stop them, then clear activeLayers.
    func stopAll(fadeSeconds: Double = 2.5) {
        guard !activeLayers.isEmpty else { return }
        let steps = 30
        let stepTime = fadeSeconds / Double(steps)
        let layersToStop = activeLayers
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(step)) { [weak self] in
                guard let self else { return }
                let t = 1.0 - Float(step) / Float(steps)
                for layer in layersToStop {
                    self.nodes[layer]?.volume = (self.layerVolumes[layer] ?? 0.35) * t
                }
                if step == steps {
                    for layer in layersToStop {
                        self.nodes[layer]?.stop()
                        self.nodes[layer]?.volume = self.layerVolumes[layer] ?? 0.35
                    }
                    self.activeLayers.removeAll()
                }
            }
        }
    }

    /// Duck all layers to level (0.0–1.0 of user volume) over fadeDuration seconds.
    func duck(to level: Float = 0.25, fadeDuration: Double = 0.4) {
        unduckTimer?.cancel()
        fade(to: level, over: fadeDuration)
    }

    /// Restore all layers to user-set volumes over fadeDuration seconds.
    func unduck(fadeDuration: Double = 1.0) {
        unduckTimer?.cancel()
        fade(to: 1.0, over: fadeDuration)
    }

    /// Called from depth pipeline. Updates adaptive binaural tier if .binaural is active.
    func updateAdaptiveDepth(_ depthScore: Float) {
        // 3-tier binaural: shallow=alpha(10Hz), mid=theta(6Hz), deep=theta(4Hz)
        let newHz: Double = depthScore > 0.70 ? 4.0 : depthScore > 0.45 ? 6.0 : 10.0
        guard newHz != customBinauralHz else { return }
        customBinauralHz = newHz
        guard activeLayers.contains(.binaural) else { return }
        // Rebuild buffer on next tier change (brief ~100ms gap is acceptable)
        buffers.removeValue(forKey: .binaural)
        nodes[.binaural]?.stop()
        startLayer(.binaural)
    }

    // MARK: - Internals

    private var isDucked: Bool = false

    private func fade(to multiplier: Float, over duration: Double) {
        isDucked = (multiplier < 1.0)
        let steps = max(1, Int(duration * 30))
        let stepTime = duration / Double(steps)
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(step)) { [weak self] in
                guard let self else { return }
                let t = Float(step) / Float(steps)
                for layer in self.activeLayers {
                    let base = self.layerVolumes[layer] ?? 0.35
                    let cur  = self.nodes[layer]?.volume ?? base
                    let target = base * multiplier
                    self.nodes[layer]?.volume = cur + t * (target - cur)
                }
                if step == steps { self.isDucked = (multiplier < 1.0) }
            }
        }
    }

    private func activate(_ layer: SoundLayer) {
        activeLayers.insert(layer)
        if let buf = buffers[layer] {
            startNode(nodes[layer]!, buffer: buf)
        } else {
            startLayer(layer)
        }
    }

    private func startLayer(_ layer: SoundLayer) {
        let vol  = layerVolumes[layer] ?? 0.35
        let beat = (layer == .binaural) ? (customBinauralHz ?? binauralPreset.beatHz) : 0.0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let buf: AVAudioPCMBuffer
            if layer.isFileBased, let fileBuf = self.loadAudioBuffer(for: layer) {
                buf = fileBuf
            } else {
                buf = self.makeBuffer(layer, beatHz: beat)
            }
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
            // Delay lets iOS finish the route-change before restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.restartEngine()
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
            self.restartEngine()
        }
    }

    private func restartEngine() {
        guard !engine.isRunning else { resumeActiveLayers(); return }
        do {
            try engine.start()
            resumeActiveLayers()
        } catch {}
    }

    private func resumeActiveLayers() {
        for layer in activeLayers {
            guard let node = self.nodes[layer],
                  let buf  = self.buffers[layer],
                  !node.isPlaying else { continue }
            node.scheduleBuffer(buf, at: nil, options: .loops)
            node.play()
        }
    }

    // MARK: - File loading

    private func loadAudioBuffer(for layer: SoundLayer) -> AVAudioPCMBuffer? {
        let names = fileNames(for: layer)
        for name in names {
            if let buf = loadM4A(named: name) { return buf }
        }
        return nil
    }

    private func fileNames(for layer: SoundLayer) -> [String] {
        switch layer {
        case .rain:    return ["rain"]
        case .thunder: return ["thunder"]
        case .ocean:   return ["ocean"]
        case .wind:    return ["wind"]
        case .brook:   return ["brook"]
        case .forest:  return ["forest"]
        case .birds:   return ["birds"]
        default:       return []
        }
    }

    private func loadM4A(named name: String) -> AVAudioPCMBuffer? {
        // Try Soundscapes subfolder first, then root of bundle (handles both XcodeGen layouts)
        let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Soundscapes")
               ?? Bundle.main.url(forResource: name, withExtension: "m4a")
        guard let url else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: frameCount) else { return nil }
        guard (try? file.read(into: buf)) != nil else { return nil }

        // If format already matches engine (44100 stereo float32), skip conversion
        let engineFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        if buf.format.sampleRate == sampleRate && buf.format.channelCount == 2 {
            return applyCrossfadeLoop(buf)
        }
        guard let converter = AVAudioConverter(from: buf.format, to: engineFmt) else { return nil }
        let outFrames = AVAudioFrameCount(
            Double(frameCount) * sampleRate / buf.format.sampleRate)
        guard let out = AVAudioPCMBuffer(pcmFormat: engineFmt, frameCapacity: outFrames) else { return nil }
        var error: NSError?
        var inputDone = false
        converter.convert(to: out, error: &error) { _, status in
            if inputDone { status.pointee = .noDataNow; return nil }
            inputDone = true
            status.pointee = .haveData
            return buf
        }
        guard error == nil else { return nil }
        return applyCrossfadeLoop(out)
    }

    /// Crossfade the tail back into the head so AVAudioPlayerNode looping is seamless.
    private func applyCrossfadeLoop(_ buf: AVAudioPCMBuffer, seconds: Double = 2.0) -> AVAudioPCMBuffer {
        let n  = Int(buf.frameLength)
        let xf = min(Int(seconds * sampleRate), n / 4)
        guard buf.format.channelCount == 2,
              let Lp = buf.floatChannelData?[0],
              let Rp = buf.floatChannelData?[1] else { return buf }

        // Blend tail into head: head[i] = head[i]*t + tail[i]*(1-t)
        for i in 0..<xf {
            let t = Float(i) / Float(xf)
            Lp[i] = Lp[i] * t + Lp[n - xf + i] * (1.0 - t)
            Rp[i] = Rp[i] * t + Rp[n - xf + i] * (1.0 - t)
        }

        // Return trimmed buffer (drop the tail that was blended into head)
        let trimLen = AVAudioFrameCount(n - xf)
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buf.format,
                                              frameCapacity: trimLen) else { return buf }
        trimmed.frameLength = trimLen
        let bytes = Int(trimLen) * MemoryLayout<Float>.size
        memcpy(trimmed.floatChannelData![0], Lp, bytes)
        memcpy(trimmed.floatChannelData![1], Rp, bytes)
        return trimmed
    }

    // MARK: - DSP buffer factory (brown noise + binaural only)

    private func makeBuffer(_ layer: SoundLayer, beatHz: Double = 0) -> AVAudioPCMBuffer {
        let n   = AVAudioFrameCount(sampleRate * bufferSecs)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        switch layer {
        case .brownNoise: fillBrownNoise(buf)
        case .binaural:   fillBinaural(buf, beatHz: beatHz)
        default:          fillBrownNoise(buf)   // fallback if file missing
        }
        return buf
    }

    // MARK: - Brown Noise (DSP)

    private func fillBrownNoise(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        // 3-pole pink approximation for brown (extra LP pole)
        var b0L: Float=0, b1L: Float=0, b2L: Float=0
        var b0R: Float=0, b1R: Float=0, b2R: Float=0
        for i in 0..<n {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            b0L = 0.99886*b0L + wL*0.0555179; b1L = 0.99332*b1L + wL*0.0750759; b2L = 0.96900*b2L + wL*0.1538520
            b0R = 0.99886*b0R + wR*0.0555179; b1R = 0.99332*b1R + wR*0.0750759; b2R = 0.96900*b2R + wR*0.1538520
            L[i] = (b0L + b1L + b2L + wL * 0.5362) * 0.11
            R[i] = (b0R + b1R + b2R + wR * 0.5362) * 0.11
        }
        norm(L, R, n: n, t: 0.70)
    }

    // MARK: - Binaural Beats (DSP)

    private func fillBinaural(_ buf: AVAudioPCMBuffer, beatHz: Double) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        let carrier = 200.0
        // Soft amplitude envelope: 0.5s fade in/out to avoid clicks on loop
        let fadeSamples = Int(0.5 * sampleRate)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var env: Float = 1.0
            if i < fadeSamples  { env = Float(i) / Float(fadeSamples) }
            if i > n - fadeSamples { env = Float(n - i) / Float(fadeSamples) }
            L[i] = Float(sin(2 * .pi * carrier            * t)) * 0.45 * env
            R[i] = Float(sin(2 * .pi * (carrier + beatHz) * t)) * 0.45 * env
        }
    }

    // MARK: - Shared DSP helpers

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
