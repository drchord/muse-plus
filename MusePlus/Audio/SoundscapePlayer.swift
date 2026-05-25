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
        case .brownNoise, .binaural, .rain, .ocean, .wind: return false
        default: return true  // thunder, brook, forest, birds remain file-based
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

    // Fade schedule: decrements 5% per successful session after 3+ sessions.
    // Applied at buffer-synthesis time so the user volume slider is unaffected.
    // Min 0.05 — fully silent binaural is useless; user should manually turn it off at that point.
    @Published var binauralFadeLevel: Float = {
        (UserDefaults.standard.object(forKey: "binauralFadeLevel") as? Float) ?? 1.0
    }() {
        didSet { _binauralAmp = 0.45 * binauralFadeLevel }
    }

    var successfulSessionCount: Int {
        UserDefaults.standard.integer(forKey: "successfulSessionCount")
    }

    /// Called at session end when session had ≥1 deep episode and ≥5 min recorded.
    /// Step size is performance-adaptive:
    ///   5% if induction was fast (first deep < 5 min) — brain is building the capability quickly
    ///   3% if induction was slow (≥5 min) — brain still benefits from the scaffold
    /// Rationale: prompt-fading literature shows fade rate should track performance, not time.
    /// If the user is struggling (slow entry), fade slower. If they're excelling, fade faster.
    func decrementBinauralFade(latencyToFirstDeep: Double?) {
        let count = successfulSessionCount + 1
        UserDefaults.standard.set(count, forKey: "successfulSessionCount")
        guard count >= 3 else { return }
        // Fast induction < 300s (5 min) = 5% step; slow = 3% step
        let step: Float = (latencyToFirstDeep ?? 9999) < 300 ? 0.05 : 0.03
        let next = max(0.05, binauralFadeLevel - step)
        guard next != binauralFadeLevel else { return }
        binauralFadeLevel = next
        UserDefaults.standard.set(next, forKey: "binauralFadeLevel")
        // B127: _binauralAmp already updated via binauralFadeLevel.didSet — source node picks it up on next render frame.
    }

    func resetBinauralFade() {
        binauralFadeLevel = 1.0
        UserDefaults.standard.set(Float(1.0), forKey: "binauralFadeLevel")
        UserDefaults.standard.set(0, forKey: "successfulSessionCount")
    }

    @Published var binauralPreset: BinauralPreset = .theta {
        didSet {
            // B127: source node picks up new preset via _binauralBeatHz update in setter
            customBinauralHz = nil
        }
    }

    // B127: adaptive binaural frequency — writes update _binauralBeatHz for the render callback immediately.
    // Main-thread writes to an aligned Double on ARM64 are single-instruction (no tearing).
    private var _customBinauralHz: Double? = nil
    var customBinauralHz: Double? {
        get { _customBinauralHz }
        set { _customBinauralHz = newValue; _binauralBeatHz = newValue ?? binauralPreset.beatHz }
    }
    private var _binauralBeatHz: Double = 6.0  // read by AVAudioSourceNode render callback
    private var _binauralAmp:    Float  = 0.45 // read by AVAudioSourceNode render callback
    private var binauralSourceNode: AVAudioSourceNode?

    private let engine = AVAudioEngine()
    // B83 — public read-only flag for SessionRecorder.appendAudioState diagnostics.
    var isEngineRunning: Bool { engine.isRunning }
    private var nodes:   [SoundLayer: AVAudioPlayerNode] = [:]
    private var buffers: [SoundLayer: AVAudioPCMBuffer]  = [:]
    private var eqs:     [SoundLayer: AVAudioUnitEQ]     = [:]
    // B126: ambient reverb node inserted between mainMixerNode and outputNode.
    // wetDryMix driven by setAmbientPresence() (0 = dry baseline, 100 = full wet).
    // Default 0 — no audible effect until ECDF-to-audio mapping activates.
    private let ambientReverb: AVAudioUnitReverb = {
        let r = AVAudioUnitReverb()
        r.loadFactoryPreset(.mediumHall)
        r.wetDryMix = 0
        return r
    }()
    private var ambientGeneration: Int = 0
    private let sampleRate: Double = 44100
    // 120s: binaural beats at all integer Hz return to phase 0 (integer × 120 = integer cycles).
    // Brown noise loops every 2 min — infrequent enough to be imperceptible in practice.
    private let bufferSecs: Double = 120

    // Volume ducking state — no cancel token needed; fade() is re-entrant via fadeGeneration.

    init() {
        // Explicit stereo format — prevents crash after BT route change
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        for layer in SoundLayer.allCases where layer != .binaural {
            let node = AVAudioPlayerNode()
            let eq   = AVAudioUnitEQ(numberOfBands: 2)
            nodes[layer] = node
            eqs[layer]   = eq
            engine.attach(node)
            engine.attach(eq)
            engine.connect(node, to: eq,                   format: fmt)
            engine.connect(eq,   to: engine.mainMixerNode, format: fmt)
            configureEQ(eq, for: layer)
        }
        // B127: binaural uses AVAudioSourceNode for phase-continuous real-time frequency updates.
        // Pre-generated looping buffer would require a 120s cycle before any frequency change takes effect.
        _binauralAmp    = 0.45 * binauralFadeLevel  // sync (didSet doesn't fire on initial declaration)
        _binauralBeatHz = binauralPreset.beatHz      // theta 6 Hz default
        let binEQ = AVAudioUnitEQ(numberOfBands: 2)
        eqs[.binaural] = binEQ
        engine.attach(binEQ)
        engine.connect(binEQ, to: engine.mainMixerNode, format: fmt)
        configureEQ(binEQ, for: .binaural)
        let srcNode = makeBinauralSourceNode(format: fmt)
        binauralSourceNode = srcNode
        engine.attach(srcNode)
        engine.connect(srcNode, to: binEQ, format: fmt)
        srcNode.volume = 0  // silent until activate(.binaural)
        // B126: insert ambientReverb between mainMixerNode and outputNode.
        // Connecting mainMixerNode → ambientReverb automatically disconnects the implicit
        // mainMixerNode → outputNode path (AVAudioEngine reconnects on explicit connect).
        engine.attach(ambientReverb)
        engine.connect(engine.mainMixerNode, to: ambientReverb,     format: fmt)
        engine.connect(ambientReverb,        to: engine.outputNode,  format: fmt)
        configureSession()
        try? engine.start()
        observeAudio()
    }

    private func configureEQ(_ eq: AVAudioUnitEQ, for layer: SoundLayer) {
        switch layer {
        case .brownNoise:
            // High-shelf cut reinforces 1/f² rolloff — 3-pole approximation leaves excess
            // high-frequency energy that sounds grainy without it.
            eq.bands[0].filterType = .highShelf
            eq.bands[0].frequency  = 6000
            eq.bands[0].gain       = -8
            eq.bands[0].bypass     = false
            eq.bands[1].bypass     = true
        case .binaural:
            // Low-pass removes aliasing above carrier while preserving the beat envelope.
            // Carrier is 200 Hz; highest beat is 20 Hz (beta) → max needed is 220 Hz.
            eq.bands[0].filterType = .lowPass
            eq.bands[0].frequency  = 500
            eq.bands[0].bypass     = false
            eq.bands[1].bypass     = true
        case .rain:
            // Parametric boost at 2.5 kHz adds "drop patter" texture to HPF noise.
            // High-shelf cut removes residual harshness above 8 kHz.
            eq.bands[0].filterType = .parametric
            eq.bands[0].frequency  = 2500
            eq.bands[0].bandwidth  = 1.5
            eq.bands[0].gain       = 4
            eq.bands[0].bypass     = false
            eq.bands[1].filterType = .highShelf
            eq.bands[1].frequency  = 8000
            eq.bands[1].gain       = -5
            eq.bands[1].bypass     = false
        case .ocean:
            // Low-shelf cut reduces LF mud from the band-pass synthesis.
            eq.bands[0].filterType = .lowShelf
            eq.bands[0].frequency  = 180
            eq.bands[0].gain       = -4
            eq.bands[0].bypass     = false
            eq.bands[1].bypass     = true
        case .wind:
            // High-shelf cut softens the LPF synthesis further for distant wind character.
            eq.bands[0].filterType = .highShelf
            eq.bands[0].frequency  = 900
            eq.bands[0].gain       = -6
            eq.bands[0].bypass     = false
            eq.bands[1].bypass     = true
        default:
            eq.bands[0].bypass = true
            eq.bands[1].bypass = true
        }
    }

    // MARK: - Public API

    func toggle(_ layer: SoundLayer) {
        activeLayers.contains(layer) ? deactivate(layer) : activate(layer)
    }

    func setVolume(_ v: Float, for layer: SoundLayer) {
        layerVolumes[layer] = v
        guard !isDucked else { return }
        if layer == .binaural {
            binauralSourceNode?.volume = v * min(proximityGain, deepStateGain)
        } else {
            nodes[layer]?.volume = v * min(proximityGain, deepStateGain)
        }
    }

    /// Fade all active layers to silence, stop them, then clear activeLayers.
    /// Captures effective gain at call time so fade starts from current audible level,
    /// not from full base — prevents jarring volume surge when called during deep state.
    func stopAll(fadeSeconds: Double = 2.5) {
        isStopping = true
        guard !activeLayers.isEmpty else {
            // No soundscape active but still stop engine — prevents drone from empty-engine restart.
            engine.stop()
            isStopping = false
            return
        }
        let steps = 30
        let stepTime = fadeSeconds / Double(steps)
        let layersToStop = activeLayers
        let effectiveAtStop = min(proximityGain, deepStateGain)  // capture now, not in closure
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(step)) { [weak self] in
                guard let self else { return }
                let t = 1.0 - Float(step) / Float(steps)
                for layer in layersToStop {
                    let vol = (self.layerVolumes[layer] ?? 0.35) * effectiveAtStop * t
                    if layer == .binaural {
                        self.binauralSourceNode?.volume = vol
                    } else {
                        self.nodes[layer]?.volume = vol
                    }
                }
                if step == steps {
                    self.binauralSourceNode?.volume = 0
                    for layer in layersToStop where layer != .binaural {
                        self.nodes[layer]?.stop()
                        self.nodes[layer]?.volume = self.layerVolumes[layer] ?? 0.35
                    }
                    self.activeLayers.removeAll()
                    self.isStopping = false
                    // B126: zero reverb tail and cancel any in-flight ambient fade.
                    self.ambientReverb.wetDryMix = 0
                    self.ambientGeneration &+= 1
                    // Stop the engine so AVAudioEngineConfigurationChange + resumeActiveLayers()
                    // cannot resurrect looping nodes during the grace window after session end.
                    // ensureRunning() / restartEngine() restarts it on next layer activation.
                    self.engine.stop()
                }
            }
        }
    }

    /// Approach-zone feedback: silently lower soundscape as user nears depth threshold.
    /// Called by DepthGate at 2 Hz. Ignored while chime duck is active.
    func setProximityGain(_ gain: Float) {
        let clamped = max(0.10, min(1.0, gain))
        guard abs(clamped - proximityGain) > 0.03 else { return }
        proximityGain = clamped
        applyProximityGain()
    }

    private func applyProximityGain() {
        guard !isDucked else { return }
        let effective = min(proximityGain, deepStateGain)
        for layer in activeLayers {
            if layer == .binaural {
                binauralSourceNode?.volume = (layerVolumes[.binaural] ?? 0.35) * effective
            } else {
                nodes[layer]?.volume = (layerVolumes[layer] ?? 0.35) * effective
            }
        }
    }

    /// Lower or raise soundscape for sustained deep-state feedback.
    /// Entry: call with 0.15 — stays down until exit.
    /// Exit:  call with 1.0 — slow fade-up IS the exit signal.
    /// Re-entry mid-fade cancels the fade-up immediately via generation counter.
    func setDeepStateGain(_ target: Float, fadeDuration: Double = 2.5) {
        let clamped = max(0.10, min(1.0, target))
        deepStateGeneration &+= 1
        let gen = deepStateGeneration
        let steps = max(1, Int(fadeDuration * 30))
        let stepTime = fadeDuration / Double(steps)
        let start = deepStateGain
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(step)) { [weak self] in
                guard let self, self.deepStateGeneration == gen else { return }
                let t = Float(step) / Float(steps)
                self.deepStateGain = start + t * (clamped - start)
                if !self.isDucked { self.applyProximityGain() }
            }
        }
    }

    func resetDeepStateGain() {
        deepStateGeneration &+= 1
        fadeGeneration &+= 1       // cancel any in-flight duck steps
        deepStateGain = 1.0
        isDucked = false
        currentDuckMultiplier = 1.0
        ambientReverb.wetDryMix = 0
        ambientGeneration &+= 1
        applyProximityGain()
    }

    /// B126: silence gap — dip deepStateGain to 0.0 over 1.0s, hold for durationSec,
    /// then restore to postGapTarget over 1.5s. Reuses deepStateGeneration so a new gap
    /// cancels any in-flight recovery. Reverb tail zeroed before gap starts.
    /// Caller must only invoke while inDeepState (DepthGate enforces).
    func enterSilenceGap(durationSec: Double, postGapTarget: Float = 0.20) {
        setAmbientPresence(0, fadeDuration: 0.5)
        setDeepStateGainAbsolute(0.0, fadeDuration: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + durationSec) { [weak self] in
            self?.setDeepStateGain(postGapTarget, fadeDuration: 1.5)
        }
    }

    /// Like setDeepStateGain but bypasses the max(0.10, ...) floor — for intentional silence.
    /// NEVER call this for normal deep-state gain changes; use setDeepStateGain instead.
    private func setDeepStateGainAbsolute(_ target: Float, fadeDuration: Double = 1.0) {
        let clamped = max(0.0, min(1.0, target))
        deepStateGeneration &+= 1
        let gen = deepStateGeneration
        let steps = max(1, Int(fadeDuration * 30))
        let stepTime = fadeDuration / Double(steps)
        let start = deepStateGain
        for step in 1...steps {
            let t = Float(step) / Float(steps)
            let v = start + (clamped - start) * t
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(step)) { [weak self] in
                guard let self, self.deepStateGeneration == gen else { return }
                self.deepStateGain = v
                if !self.isDucked { self.applyProximityGain() }
            }
        }
    }

    /// B126: continuous ECDF-to-audio mapping via reverb wetDryMix (0–100).
    /// p in [0, 1]: 0 = dry, 1 = full wet. Slewed over fadeDuration seconds so changes
    /// are felt, not tracked (Brewer 2013: prominent feedback disrupts effortless awareness).
    /// Guard: caller must not invoke this while inDeepState — DepthGate enforces.
    func setAmbientPresence(_ p: Float, fadeDuration: Double = 3.0) {
        let target = max(0, min(1, p)) * 100   // wetDryMix range 0–100
        let steps = max(1, Int(fadeDuration * 30))
        let stepTime = fadeDuration / Double(steps)
        ambientGeneration &+= 1
        let gen = ambientGeneration
        let start = ambientReverb.wetDryMix
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let mix = start + (target - start) * t
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(i)) { [weak self] in
                guard let self, self.ambientGeneration == gen else { return }
                self.ambientReverb.wetDryMix = mix
            }
        }
    }

    /// Duck all layers to level (0.0–1.0 of user volume) over fadeDuration seconds.
    func duck(to level: Float = 0.25, fadeDuration: Double = 0.4) {
        fade(to: level, over: fadeDuration)
    }

    /// Restore all layers to user-set volumes over fadeDuration seconds.
    func unduck(fadeDuration: Double = 1.0) {
        fade(to: 1.0, over: fadeDuration)
    }

    /// Called from depth pipeline every 0.5s. Tracks iTPF and writes to _binauralBeatHz via
    /// customBinauralHz setter. B127: AVAudioSourceNode picks up changes on the next render frame
    /// (~23ms) — phase-continuous, no gap. 0.10 Hz hysteresis prevents spurious writes.
    /// iTPF: individual theta peak in Hz from ITPFTracker (nil = tracker not yet reliable → no-op).
    func updateAdaptiveDepth(_ depthScore: Float, iTPF: Float? = nil) {
        guard let rawHz = iTPF.map({ Double($0) }) else { return }
        let newHz = max(4.0, min(8.0, rawHz))      // clamp to theta band; use iTPF directly
        guard abs(newHz - _binauralBeatHz) > 0.10 else { return }
        customBinauralHz = newHz
    }

    /// Set binaural frequency from iTPF at deep state entry (Option B).
    /// Only fires if binaural layer is active and new Hz differs by >0.3 from current.
    /// B127: AVAudioSourceNode picks up the change on next render frame (~23ms), phase-continuous.
    /// Valid iTPF range: 4.0–9.0 Hz (frontal theta band).
    func setAdaptiveBinauralIfActive(hz: Double) {
        guard activeLayers.contains(.binaural) else { return }
        guard hz > 4.0, hz < 9.0 else { return }
        let current = customBinauralHz ?? binauralPreset.beatHz
        guard abs(hz - current) > 0.3 else { return }
        customBinauralHz = hz
    }

    // MARK: - Internals

    private var isDucked:              Bool  = false
    private var isStopping:            Bool  = false   // blocks resumeActiveLayers during session-end fade
    private var proximityGain:         Float = 1.0     // set by DepthGate approach duck [0.10, 1.0]
    private var deepStateGain:         Float = 1.0     // 0.15 while in deep state, 1.0 otherwise
    private var deepStateGeneration:   Int   = 0       // cancels stale setDeepStateGain steps
    private var fadeGeneration:        Int   = 0       // cancels stale fade() steps on new fade
    private var currentDuckMultiplier: Float = 1.0     // last duck target; used to match new/resumed layers

    private func fade(to multiplier: Float, over duration: Double) {
        // isDucked only when chime actually lowers volume below current effective level.
        // Exit case: deepStateGain=0.15, duck target=0.18 — target > floor, isActuallyDucking
        // = false → guard return → setDeepStateGain rises unimpeded, preserving exit signal.
        // Unduck after entry chime: deepStateGain=0.15, target=1.0 → same guard → snaps to 0.15.
        let capturedEffective = min(proximityGain, deepStateGain)
        let isActuallyDucking = min(multiplier, deepStateGain) < capturedEffective - 0.02
        isDucked = isActuallyDucking
        guard isActuallyDucking else {
            applyProximityGain()   // snap to current floor (clears stale duck level from entry chime)
            return
        }
        currentDuckMultiplier = multiplier
        // Capture starting volumes synchronously — true linear interpolation regardless of
        // any concurrent applyProximityGain calls between steps.
        let startVols: [SoundLayer: Float] = Dictionary(
            uniqueKeysWithValues: activeLayers.compactMap { layer -> (SoundLayer, Float)? in
                if layer == .binaural { return binauralSourceNode.map { (layer, $0.volume) } }
                return nodes[layer].map { (layer, $0.volume) }
            }
        )
        fadeGeneration &+= 1
        let gen = fadeGeneration
        let steps = max(1, Int(duration * 30))
        let stepTime = duration / Double(steps)
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(step)) { [weak self] in
                guard let self, self.fadeGeneration == gen else { return }
                let t = Float(step) / Float(steps)
                for layer in self.activeLayers {
                    let base     = self.layerVolumes[layer] ?? 0.35
                    let startVol = startVols[layer] ?? base
                    // Deep state owns the floor: chime can never push volume below deepStateGain.
                    let stepTarget = base * min(multiplier, self.deepStateGain)
                    let newVol = startVol + t * (stepTarget - startVol)
                    if layer == .binaural {
                        self.binauralSourceNode?.volume = newVol
                    } else {
                        self.nodes[layer]?.volume = newVol
                    }
                }
                if step == steps {
                    let finalWouldBe   = min(multiplier, self.deepStateGain)
                    let finalEffective = min(self.proximityGain, self.deepStateGain)
                    self.isDucked = finalWouldBe < finalEffective - 0.02
                    if !self.isDucked { self.applyProximityGain() }
                }
            }
        }
    }

    private func activate(_ layer: SoundLayer) {
        isStopping = false
        activeLayers.insert(layer)
        if layer == .binaural {
            // B127: source node renders while engine is running; ensure it's started before unmuting.
            ensureRunning()
            let vol = layerVolumes[.binaural] ?? 0.35
            let effective = min(proximityGain, deepStateGain)
            binauralSourceNode?.volume = isDucked
                ? vol * min(currentDuckMultiplier, deepStateGain)
                : vol * effective
        } else if let buf = buffers[layer] {
            startNode(nodes[layer]!, buffer: buf)
        } else {
            startLayer(layer)
        }
    }

    private func startLayer(_ layer: SoundLayer) {
        guard layer != .binaural else { return }  // B127: binaural uses AVAudioSourceNode, not startLayer
        let vol  = layerVolumes[layer] ?? 0.35
        let beat = 0.0
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
                // Match duck level when chime active — new layer must not sound louder than peers.
                node.volume = self.isDucked
                    ? vol * min(self.currentDuckMultiplier, self.deepStateGain)
                    : vol * min(self.proximityGain, self.deepStateGain)
                self.startNode(node, buffer: buf)
            }
        }
    }

    private func deactivate(_ layer: SoundLayer) {
        activeLayers.remove(layer)
        if layer == .binaural {
            binauralSourceNode?.volume = 0
        } else {
            nodes[layer]?.stop()
        }
    }

    private func startNode(_ node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) {
        node.stop()
        ensureRunning()
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        node.play()
    }

    // MARK: - Binaural Streaming (B127)

    /// Phase-continuous binaural render callback. Reads _binauralBeatHz and _binauralAmp
    /// which are written on the main thread. ARM64 aligned 64/32-bit stores are single-instruction;
    /// a torn read yields a value between two nearby frequencies — inaudible in practice.
    private func makeBinauralSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        var phaseL: Double = 0.0
        var phaseR: Double = 0.0
        let sr = sampleRate
        let carrier = 200.0
        return AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let abl    = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let beatHz = self._binauralBeatHz
            let amp    = Double(self._binauralAmp)
            let incL   = carrier         / sr
            let incR   = (carrier + beatHz) / sr
            let n      = Int(frameCount)
            if abl.count >= 2,
               let L = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let R = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<n {
                    L[i] = Float(sin(phaseL * 2.0 * .pi) * amp)
                    R[i] = Float(sin(phaseR * 2.0 * .pi) * amp)
                    phaseL += incL; if phaseL >= 1.0 { phaseL -= 1.0 }
                    phaseR += incR; if phaseR >= 1.0 { phaseR -= 1.0 }
                }
            }
            return noErr
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
        guard !isStopping else { return }  // block resurrection during session-end fade
        for layer in activeLayers {
            if layer == .binaural { continue }  // B127: source node survives engine restart automatically
            guard let node = self.nodes[layer],
                  let buf  = self.buffers[layer],
                  !node.isPlaying else { continue }
            node.scheduleBuffer(buf, at: nil, options: .loops)
            node.play()
        }
        // Restore correct gain after route change.
        if isDucked {
            for layer in activeLayers {
                let vol = (layerVolumes[layer] ?? 0.35) * min(currentDuckMultiplier, deepStateGain)
                if layer == .binaural {
                    binauralSourceNode?.volume = vol
                } else {
                    nodes[layer]?.volume = vol
                }
            }
        } else {
            applyProximityGain()
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

        // Equal-power crossfade: sin²+cos²=1 keeps energy constant through the blend.
        // Linear crossfade has a -3 dB dip at the midpoint — audible as a volume dip in
        // textured ambience (brown noise, rain). sin/cos eliminates it.
        for i in 0..<xf {
            let θ       = Float(i) / Float(xf) * Float.pi * 0.5
            let fadeIn  = sin(θ)   // 0 → 1  (head coming in)
            let fadeOut = cos(θ)   // 1 → 0  (tail going out)
            Lp[i] = Lp[i] * fadeIn + Lp[n - xf + i] * fadeOut
            Rp[i] = Rp[i] * fadeIn + Rp[n - xf + i] * fadeOut
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

    // MARK: - DSP buffer factory

    private func makeBuffer(_ layer: SoundLayer, beatHz: Double = 0) -> AVAudioPCMBuffer {
        let n   = AVAudioFrameCount(sampleRate * bufferSecs)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        switch layer {
        case .brownNoise:
            fillBrownNoise(buf)
            // Crossfade blends tail into warmed-up head. Filter warmup ensures head samples
            // are in steady state so the blend is amplitude-matched at both ends.
            return applyCrossfadeLoop(buf)
        case .binaural:
            fillBinaural(buf, beatHz: beatHz)
            return buf   // phase-continuous at 120s for all integer-Hz beats
        case .rain:
            fillRain(buf)
            return applyCrossfadeLoop(buf)
        case .ocean:
            fillOcean(buf)
            return applyCrossfadeLoop(buf)
        case .wind:
            fillWind(buf)
            return applyCrossfadeLoop(buf)
        default:
            fillBrownNoise(buf)
            return applyCrossfadeLoop(buf)
        }
    }

    // MARK: - Rain (DSP)
    // First-order HPF on white noise (fc ≈ 800 Hz) with decorrelated stereo.
    // AM at exactly 4 cycles / 120s → phase-continuous at loop boundary (no AM click).
    // α = τ/(τ+dt), τ=1/(2π·800 Hz), dt=1/44100 Hz → α ≈ 0.898.

    private func fillRain(_ buf: AVAudioPCMBuffer) {
        let n  = Int(buf.frameLength)
        let L  = buf.floatChannelData![0]
        let R  = buf.floatChannelData![1]
        let αH: Float = 0.898
        var hL: Float = 0, hR: Float = 0
        var xL: Float = 0, xR: Float = 0
        for _ in 0..<2000 {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            hL = αH * (hL + wL - xL); xL = wL
            hR = αH * (hR + wR - xR); xR = wR
        }
        for i in 0..<n {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            hL = αH * (hL + wL - xL); xL = wL
            hR = αH * (hR + wR - xR); xR = wR
            let am = Float(0.80 + 0.20 * sin(2 * .pi * (4.0 / 120.0) * Double(i) / sampleRate))
            L[i] = hL * am
            R[i] = hR * am
        }
        norm(L, R, n: n, t: 0.70)
    }

    // MARK: - Ocean (DSP)
    // Band-pass noise (LP 600 Hz → HP 60 Hz) shaped by two overlapping wave envelopes.
    // Wave periods use integer-cycle frequencies (12 and 8 cycles / 120s) so the envelope
    // returns to its t=0 value exactly at the loop boundary — no amplitude click.

    private func fillOcean(_ buf: AVAudioPCMBuffer) {
        let n  = Int(buf.frameLength)
        let L  = buf.floatChannelData![0]
        let R  = buf.floatChannelData![1]
        let αLP: Float = 0.9181  // LP α = exp(-2π·600/44100)
        let αHP: Float = 0.9915  // HP α = τ/(τ+dt), τ=1/(2π·60 Hz)
        var lpL: Float = 0, lpR: Float = 0
        var hpL: Float = 0, hpR: Float = 0
        var prevL: Float = 0, prevR: Float = 0
        for _ in 0..<4000 {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lpL = αLP * lpL + (1 - αLP) * wL
            lpR = αLP * lpR + (1 - αLP) * wR
            hpL = αHP * (hpL + lpL - prevL); prevL = lpL
            hpR = αHP * (hpR + lpR - prevR); prevR = lpR
        }
        for i in 0..<n {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lpL = αLP * lpL + (1 - αLP) * wL
            lpR = αLP * lpR + (1 - αLP) * wR
            hpL = αHP * (hpL + lpL - prevL); prevL = lpL
            hpR = αHP * (hpR + lpR - prevR); prevR = lpR
            let t  = Double(i) / sampleRate
            // Half-rectified squared sine: natural wave swell shape (quiet trough, crashing crest).
            let wA = max(0.0, sin(2 * .pi * (12.0 / 120.0) * t))
            let wB = max(0.0, sin(2 * .pi * ( 8.0 / 120.0) * t + .pi / 2))
            let envelope = Float(0.25 + 0.50 * wA * wA + 0.25 * wB * wB)
            L[i] = hpL * envelope
            R[i] = hpR * envelope
        }
        norm(L, R, n: n, t: 0.70)
    }

    // MARK: - Wind (DSP)
    // LP-filtered noise (fc ≈ 200 Hz) with two gusting oscillators.
    // Both use integer-cycle frequencies (2 and 4 cycles / 120s) → phase-continuous loop.
    // α = exp(-2π·200/44100) ≈ 0.9719.

    private func fillWind(_ buf: AVAudioPCMBuffer) {
        let n  = Int(buf.frameLength)
        let L  = buf.floatChannelData![0]
        let R  = buf.floatChannelData![1]
        let αLP: Float = 0.9719
        var lpL: Float = 0, lpR: Float = 0
        for _ in 0..<4000 {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lpL = αLP * lpL + (1 - αLP) * wL
            lpR = αLP * lpR + (1 - αLP) * wR
        }
        for i in 0..<n {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            lpL = αLP * lpL + (1 - αLP) * wL
            lpR = αLP * lpR + (1 - αLP) * wR
            let t = Double(i) / sampleRate
            let gust = Float(0.50 + 0.32 * sin(2 * .pi * (2.0 / 120.0) * t)
                                   + 0.18 * sin(2 * .pi * (4.0 / 120.0) * t + 1.0))
            L[i] = lpL * gust
            R[i] = lpR * gust
        }
        norm(L, R, n: n, t: 0.70)
    }

    // MARK: - Brown Noise (DSP)

    private func fillBrownNoise(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        var b0L: Float=0, b1L: Float=0, b2L: Float=0
        var b0R: Float=0, b1R: Float=0, b2R: Float=0
        // Warmup: drive filter to ergodic steady state before writing output samples.
        // Without this, the first ~1000 samples are systematically low-amplitude
        // (filter starting from zero), audible as a volume dip each 120s loop cycle.
        // 2000 samples >> slowest pole time constant ≈ 877 samples (1/(1-0.99886)).
        for _ in 0..<2000 {
            let wL = Float.random(in: -1...1), wR = Float.random(in: -1...1)
            b0L = 0.99886*b0L + wL*0.0555179; b1L = 0.99332*b1L + wL*0.0750759; b2L = 0.96900*b2L + wL*0.1538520
            b0R = 0.99886*b0R + wR*0.0555179; b1R = 0.99332*b1R + wR*0.0750759; b2R = 0.96900*b2R + wR*0.1538520
        }
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
        let amp = Double(0.45 * binauralFadeLevel)
        // No fade envelope — at 30s both carrier (200 Hz × 30 = 6000 cycles) and beat
        // (integer Hz × 30 = integer cycles) return to phase 0. Loop is click-free.
        for i in 0..<n {
            let t = Double(i) / sampleRate
            L[i] = Float(sin(2 * .pi * carrier            * t) * amp)
            R[i] = Float(sin(2 * .pi * (carrier + beatHz) * t) * amp)
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
