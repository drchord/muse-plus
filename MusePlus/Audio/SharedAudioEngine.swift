import AVFoundation

final class SharedAudioEngine {
    static let shared = SharedAudioEngine()

    let engine = AVAudioEngine()

    private init() {
        configureSession()
        observeNotifications()
        try? engine.start()
    }

    // Stop → attach+connect → restart so topology changes are safe on a running engine
    func addNode(_ node: AVAudioNode, format: AVAudioFormat? = nil) {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if wasRunning { try? engine.start() }
    }

    func restart() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    // MARK: - Private

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeNotifications() {
        // Engine graph changed (e.g. Bluetooth route change)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in self?.restart() }

        // Audio session interrupted (phone call, Siri, etc.)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw  = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            self?.configureSession()
            self?.restart()
        }

        // Media services reset (rare but fatal if unhandled)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.configureSession()
            self?.restart()
        }
    }
}
