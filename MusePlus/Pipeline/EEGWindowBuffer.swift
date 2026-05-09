/// EEGWindowBuffer.swift
/// MusePlus — 1-second sliding-window buffer for sidecar EEG denoising
///
/// Architecture (B83):
///   • `MuseClient.handleEEG` calls `EEGWindowBuffer.shared.ingest(pkt)` on every
///     SDK callback (after the existing `eegPacket.send(pkt)` call).
///   • Once each of the 4 canonical channels (TP9=0, AF7=1, AF8=2, TP10=3) has
///     accumulated 256 samples (1 second at 256 Hz), the buffer dispatches a
///     denoise pass on a low-priority background queue.
///   • Result emits to `SessionRecorder.appendDenoiseStats(...)` as a NDJSON
///     `_type:"denoiseStats"` line. The CLEANED signal is NOT yet routed back
///     into `EEGPipeline` — it's a sidecar measurement only. B84 decides
///     whether to flip the switch based on tap-to-mark validation.
///   • The raw EEG continues to feed the live pipeline unchanged. Real-time
///     latency budget (depth scoring, ECDF) is preserved.
///
/// Toggle: `UserDefaults.standard.bool(forKey: "eegDenoiseEnabled")` defaults to
/// TRUE in B83 because we want stats from every session for offline analysis.
/// Set to FALSE in Settings to skip denoising entirely (saves CPU when needed).
///
/// Thread model: a private serial DispatchQueue. SDK callback thread → ingest →
/// queue.async → window-full check → denoise on same queue (off main).
///
/// Performance: db4 SWT 5-level + Potato + rASR-lite on 4×256 window measured
/// at < 5 ms on iPhone 12 in development; budget is 1 sec / window so we have
/// 200× headroom. CPU footprint negligible against EEGPipeline FFT cost.

import Foundation

final class EEGWindowBuffer {

    static let shared = EEGWindowBuffer()

    private let queue = DispatchQueue(label: "com.drchord.museplus.eegwindow",
                                       qos: .utility)
    private let denoiser = EEGDenoiser(sampleRate: 256.0)
    private let windowSize = 256                  // 1 sec @ 256 Hz
    private var buffers: [[Float]] = [[], [], [], []]

    private init() {}

    /// Ingest one packet's worth of samples per channel.
    /// `packet.channels` may have 4 (legacy Muse) or 8 (Athena MS-03) entries —
    /// we only use indices 0..<4 (canonical 4-channel layout).
    func ingest(_ packet: EEGPacket) {
        // Defensive copy on caller's thread; queue.async receives `Float` values not packet refs.
        guard packet.channels.count >= 4 else { return }
        let s0 = packet.channels[0]
        let s1 = packet.channels[1]
        let s2 = packet.channels[2]
        let s3 = packet.channels[3]

        queue.async { [weak self] in
            guard let self else { return }

            // Each EEG packet from the Muse SDK carries roughly 12 samples (varies),
            // but `EEGPacket.channels` flattens to one current-sample-per-channel
            // value. We append one sample per channel per packet here. Confirm
            // against MuseClient.handleEEG: yes, that's the contract.
            self.buffers[0].append(s0)
            self.buffers[1].append(s1)
            self.buffers[2].append(s2)
            self.buffers[3].append(s3)

            // Window full — denoise + emit stats + slide window.
            if self.buffers[0].count >= self.windowSize {
                self.processWindowLocked()
            }
        }
    }

    /// Reset on disconnect / new session. Idempotent.
    func reset() {
        queue.async { [weak self] in
            self?.buffers = [[], [], [], []]
        }
    }

    // MARK: - Private

    private func processWindowLocked() {
        // Fast-path bypass when toggle is OFF.
        let enabled = UserDefaults.standard.object(forKey: "eegDenoiseEnabled") as? Bool ?? true
        guard enabled else {
            // Drain to keep buffers from growing unbounded.
            for i in 0..<4 {
                if buffers[i].count > windowSize {
                    buffers[i].removeFirst(buffers[i].count - windowSize)
                }
            }
            SessionRecorder.shared.appendDenoiseStats(
                alphaPowerRatio: 1.0,
                spikeRmsReduction: 1.0,
                spikesRemoved: 0,
                potatoFlagged: false,
                potatoDistance: 0,
                asrComponentsReplaced: 0,
                bypassReason: "denoise_disabled"
            )
            return
        }

        // Take the leading windowSize samples per channel; keep remainder for next pass.
        var window = [[Float]]()
        window.reserveCapacity(4)
        for i in 0..<4 {
            let frame = Array(buffers[i].prefix(windowSize))
            window.append(frame)
            buffers[i].removeFirst(windowSize)
        }

        let result = denoiser.denoise(window: window)
        let s = result.stats

        // Read potato/asr fields if EEGDenoiseStats has them. Fields beyond the
        // original 3 are added by the Potato+rASR extension; reflection-style
        // access via Mirror keeps this resilient if the extension hasn't landed.
        let mirror = Mirror(reflecting: s)
        var potatoFlagged = false
        var potatoDistance: Float = 0
        var asrReplaced: Int = 0
        for child in mirror.children {
            switch child.label {
            case "potatoFlagged":         potatoFlagged   = (child.value as? Bool)  ?? false
            case "potatoDistance":        potatoDistance  = (child.value as? Float) ?? 0
            case "asrComponentsReplaced": asrReplaced     = (child.value as? Int)   ?? 0
            default: break
            }
        }

        SessionRecorder.shared.appendDenoiseStats(
            alphaPowerRatio: s.alphaPowerRatio,
            spikeRmsReduction: s.spikeRmsReduction,
            spikesRemoved: s.spikesRemoved,
            potatoFlagged: potatoFlagged,
            potatoDistance: potatoDistance,
            asrComponentsReplaced: asrReplaced,
            bypassReason: nil
        )
    }
}
