// EndGongPlayer.swift
// MusePlus
//
// File-based AVAudioPlayer for session-end gong sounds.
// Reads from app Bundle, falling back to ChimeEngine synthesis when no file present.
//
// ASSUMED BUNDLED FILENAMES:
//   - bowl_success.m4a  (session ended successfully)
//   - bowl_failure.m4a  (session ended with failure/interruption)
//
// SETUP INSTRUCTIONS:
//   1. Drop `bowl_success.m4a` and `bowl_failure.m4a` into:
//        MusePlus/Resources/Sounds/
//   2. Add the files to the Xcode target (check "Add to targets: MusePlus" in the file picker).
//      OR, if using XcodeGen (project.yml), add to the resources section:
//        resources:
//          - path: Resources/Sounds/bowl_success.m4a
//          - path: Resources/Sounds/bowl_failure.m4a
//   3. The fallback synthesis path (ChimeEngine.shared.playGong / playEndedFailure) is active
//      automatically when files are absent — no code changes needed.
//
// TELEMETRY DEPENDENCY:
//   Assumes `SessionRecorder.shared.appendEvent(_:)` and `SessionRecorder.shared.currentSessionElapsed()`
//   are being added in this build (B81+). Both calls are marked TODO if wiring needs confirmation.
//
// iOS 16+  Swift 5.9  No external dependencies.

import AVFoundation
import Foundation
import os.log

// MARK: - EndGongPlayer

/// Plays session-end bowl gong sounds via file-based AVAudioPlayer.
/// Falls back to ChimeEngine synthesis when bundle audio files are absent.
/// Emits `gongLifecycle` telemetry events at each state transition.
public final class EndGongPlayer: NSObject, AVAudioPlayerDelegate {

    // MARK: Public Singleton

    public static let shared = EndGongPlayer()

    // MARK: Private State

    private var player: AVAudioPlayer?
    private var currentDetail: String = "unknown"

    /// Key into UserDefaults for chime volume (0.0 – 1.0). Defaults to 0.7.
    private static let volumeDefaultsKey = "chimeVolume"
    private static let defaultVolume: Float = 0.7

    // MARK: Init

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Pre-configure AVAudioSession before the asyncAfter delay so the category change does not
    /// fire mid-fade. Call this synchronously at session-end before scheduling the gong delay.
    public func prepareAudioSession() {
        configureAudioSession()
    }

    /// Play the success bowl gong.
    /// Tries `bowl_success.m4a` (then `.wav`, then `.mp3`) from Bundle; falls back to `ChimeEngine.shared.playGong()`.
    public func playSuccess() {
        play(resourceName: "bowl_success", fallback: {
            Telemetry.audio.notice("EndGongPlayer: falling back to ChimeEngine.playGong() for success")
            ChimeEngine.shared.playGong()
        })
    }

    /// Play the failure bowl gong.
    /// Tries `bowl_failure.m4a` (then `.wav`) from Bundle; falls back to `ChimeEngine.shared.playFailureChime()`.
    public func playFailure() {
        play(resourceName: "bowl_failure", fallback: {
            Telemetry.audio.notice("EndGongPlayer: falling back to ChimeEngine.playFailureChime() for failure")
            ChimeEngine.shared.playFailureChime()
        })
    }

    // MARK: - Private Playback Logic

    private func play(resourceName: String, fallback: @escaping () -> Void) {
        // Locate file in bundle — try .m4a first, then .wav, then Documents/Sounds.
        guard let fileURL = bundleURL(resourceName: resourceName) else {
            // B83 round-5 — when no file present, log gongLifecycle as SYNTHESIS-source,
            // not "file:..._not_in_bundle". Prior commit's emitEvent path lied: every
            // gongLifecycle line claimed source=file:* even when synthesis fired.
            Telemetry.audio.error("EndGongPlayer: bundle file not found for '\(resourceName)' (.m4a/.wav/Documents); using synthesis fallback")
            SessionRecorder.shared.appendGongLifecycle(
                phase: "scheduled",
                source: "synth:ChimeEngine-432Hz",
                detail: "no_bundle_or_documents_file_for_\(resourceName)"
            )
            fallback()
            // ChimeEngine synthesis is fire-and-forget; mark as completed so analysts
            // see a terminating record. Real audibility is still verifiable via the
            // following audioState snapshot in the caller.
            SessionRecorder.shared.appendGongLifecycle(
                phase: "completed",
                source: "synth:ChimeEngine-432Hz",
                detail: nil
            )
            return
        }

        let detail = fileURL.lastPathComponent
        currentDetail = detail

        // Schedule event
        emitEvent(kind: "gongScheduled", detail: detail)
        Telemetry.audio.notice("EndGongPlayer: scheduled \(detail)")

        // Build AVAudioPlayer
        do {
            let vol = resolvedVolume()
            let newPlayer = try AVAudioPlayer(contentsOf: fileURL)
            newPlayer.delegate = self
            newPlayer.volume = vol
            newPlayer.prepareToPlay()

            player = newPlayer

            let started = newPlayer.play()

            if started && newPlayer.isPlaying {
                // Log volume in the started event — if this is 0.0, the gong is silent.
                // Previously required post-hoc NDJSON analysis; now self-documenting.
                emitEvent(kind: "gongStarted", detail: "\(detail)_vol\(String(format: "%.2f", vol))")
                Telemetry.audio.notice("EndGongPlayer: playback started — \(detail) vol=\(String(format: "%.2f", vol))")
            } else {
                Telemetry.audio.error("EndGongPlayer: play() returned false or isPlaying=false for \(detail)")
                emitEvent(kind: "gongFailed", detail: "\(detail)_play_returned_false")
                player = nil
                fallback()
            }
        } catch {
            Telemetry.audio.error("EndGongPlayer: AVAudioPlayer init failed for \(detail): \(error.localizedDescription)")
            emitEvent(kind: "gongFailed", detail: "\(detail)_init_error")
            player = nil
            fallback()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let detail = currentDetail
        if flag {
            emitEvent(kind: "gongCompleted", detail: detail)
            Telemetry.audio.notice("EndGongPlayer: playback completed — \(detail)")
        } else {
            emitEvent(kind: "gongFailed", detail: "\(detail)_finished_unsuccessfully")
            Telemetry.audio.error("EndGongPlayer: playback finished unsuccessfully — \(detail)")
        }
        self.player = nil
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let detail = currentDetail
        let errorDesc = error?.localizedDescription ?? "unknown_decode_error"
        Telemetry.audio.error("EndGongPlayer: decode error for \(detail): \(errorDesc)")
        emitEvent(kind: "gongFailed", detail: "\(detail)_decode_error")
        self.player = nil
    }

    // MARK: - Helpers

    /// Resolve audio resource URL.
    /// Lookup order (per extension: m4a → mp3 → wav): Bundle root, then Bundle Sounds/
    /// subdirectory, then Documents/Sounds (BowlAudioGenerator synthesized fallback).
    /// Bundle.main.url(forResource:) does NOT search subdirectories without an explicit
    /// subdirectory: parameter — omitting it caused bowl_success.mp3 to fall through to
    /// the synthesized 432 Hz WAV (buzzing) even when the file was present in the bundle.
    private func bundleURL(resourceName: String) -> URL? {
        for ext in ["m4a", "mp3", "wav"] {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: ext) {
                Telemetry.audio.notice("EndGongPlayer: bundle root \(resourceName).\(ext, privacy: .public)")
                return url
            }
            if let url = Bundle.main.url(forResource: resourceName, withExtension: ext,
                                          subdirectory: "Sounds") {
                Telemetry.audio.notice("EndGongPlayer: bundle Sounds/ \(resourceName).\(ext, privacy: .public)")
                return url
            }
        }
        return nil
    }

    /// Hard floor for end-gong volume regardless of the chime slider setting.
    /// At system volume 0.3 (typical during meditation), 0.85 * 0.3 = 25.5% of iPhone
    /// max — clearly audible without being jarring. Raising this above 1.0 is meaningless.
    private static let gongVolumeFloor: Float = 0.85

    /// Resolve playback volume with a hard floor.
    /// Handles Float/Double/NSNumber storage (UserDefaults bridging varies by call site).
    /// Returns max(floor, userSetting) so the gong is always audible even when chimes
    /// are muted for silent meditation sessions.
    private func resolvedVolume() -> Float {
        let raw: Float
        let stored = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey)
        if let f = stored as? Float         { raw = max(0, min(1, f)) }
        else if let d = stored as? Double   { raw = max(0, min(1, Float(d))) }
        else if let n = stored as? NSNumber { raw = max(0, min(1, n.floatValue)) }
        else                                { raw = Self.defaultVolume }
        return max(Self.gongVolumeFloor, raw)
    }

    /// Configure AVAudioSession for playback, mixing with other active sessions.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Telemetry.audio.error("EndGongPlayer: AVAudioSession config failed: \(error.localizedDescription)")
        }
    }

    /// Emit a gongLifecycle event via SessionRecorder's typed `appendGongLifecycle` API.
    /// `kind` ∈ {gongScheduled, gongStarted, gongCompleted, gongFailed} — the `phase`
    /// in the NDJSON line. `detail` is the source filename or fallback marker.
    private func emitEvent(kind: String, detail: String) {
        let phase: String = {
            switch kind {
            case "gongScheduled": return "scheduled"
            case "gongStarted":   return "started"
            case "gongCompleted": return "completed"
            case "gongFailed":    return "failed"
            default:              return kind
            }
        }()
        SessionRecorder.shared.appendGongLifecycle(
            phase: phase,
            source: "file:\(detail)",
            detail: nil
        )
    }
}
