// BowlAudioGenerator.swift
// MusePlus
//
// Generates Tibetan-bowl-like .wav files in Documents/Sounds/ at first app launch.
// Call generateIfNeeded() once from MusePlusApp.init().
// EndGongPlayer uses successURL() / failureURL() as a second fallback after Bundle lookup.
//
// iOS 16+, Swift 5.9, AVFoundation only.

import Foundation
import AVFoundation
import os.log

// Bump to force regeneration of cached .wav files on next launch.
private let kBowlAudioVersion = "B91"

public final class BowlAudioGenerator {

    // MARK: - Shared instance

    public static let shared = BowlAudioGenerator()
    private init() {}

    // MARK: - Logging

    private let log = Logger(subsystem: "com.museplus", category: "Telemetry.audio")

    // MARK: - Public API

    /// Generate bowl_success.wav and bowl_failure.wav in Documents/Sounds/.
    /// Re-generates if kBowlAudioVersion has changed since last write.
    public func generateIfNeeded() {
        let storedVersion = UserDefaults.standard.string(forKey: "bowlAudioVersion")
        let needsRegen = storedVersion != kBowlAudioVersion

        let dir = soundsDirectory()
        createDirectoryIfNeeded(dir)

        let successFile = dir.appendingPathComponent("bowl_success.wav")
        let failureFile = dir.appendingPathComponent("bowl_failure.wav")

        if needsRegen || !FileManager.default.fileExists(atPath: successFile.path) {
            try? FileManager.default.removeItem(at: successFile)
            do {
                try writeSuccessBowl(to: successFile)
                log.info("BowlAudioGenerator: wrote bowl_success.wav v\(kBowlAudioVersion)")
            } catch {
                log.error("BowlAudioGenerator: failed to write bowl_success.wav – \(error.localizedDescription)")
            }
        }

        if needsRegen || !FileManager.default.fileExists(atPath: failureFile.path) {
            try? FileManager.default.removeItem(at: failureFile)
            do {
                try writeFailureBowl(to: failureFile)
                log.info("BowlAudioGenerator: wrote bowl_failure.wav v\(kBowlAudioVersion)")
            } catch {
                log.error("BowlAudioGenerator: failed to write bowl_failure.wav – \(error.localizedDescription)")
            }
        }

        if needsRegen {
            UserDefaults.standard.set(kBowlAudioVersion, forKey: "bowlAudioVersion")
        }
    }

    /// URL of the generated success bowl file, or nil if it does not exist.
    public func successURL() -> URL? {
        let url = soundsDirectory().appendingPathComponent("bowl_success.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// URL of the generated failure bowl file, or nil if it does not exist.
    public func failureURL() -> URL? {
        let url = soundsDirectory().appendingPathComponent("bowl_failure.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Directory helpers

    private func soundsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sounds", isDirectory: true)
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            log.error("BowlAudioGenerator: cannot create Sounds dir – \(error.localizedDescription)")
        }
    }

    // MARK: - Audio format

    /// 44100 Hz, mono, 16-bit signed integer PCM (little-endian).
    private func monoFormat() -> AVAudioFormat {
        // Use standard PCM format; AVAudioFormat will produce WAVE when written via AVAudioFile.
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44100,
            channels: 1,
            interleaved: true
        ) else {
            // B83 round-6 — fallback initializer ALSO returns Optional; force-unwrap is
            // safe here because both the int16 and standard 44.1k mono initialisers
            // are documented to succeed on iOS 16+ with these parameters. If both
            // somehow returned nil the app couldn't synthesize audio at all.
            return AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        }
        return fmt
    }

    // MARK: - Success bowl synthesis

    /// Tibetan-bowl model matching ChimeEngine.scheduleBowl.
    /// Fundamental 432 Hz, inharmonic partials, 8-second decay, 25 ms attack, reverb tail.
    private func writeSuccessBowl(to url: URL) throws {
        let sampleRate: Double = 44100
        let duration: Double  = 8.0
        let frameCount        = AVAudioFrameCount(sampleRate * duration)

        let format = monoFormat()

        // Partial definition: (ratio, weight, decayMult)
        let partials: [(ratio: Double, weight: Double, decayMult: Double)] = [
            (1.000, 1.00, 1.0),
            (2.756, 0.45, 2.2),
            (5.404, 0.20, 4.1),
            (8.900, 0.08, 7.8)
        ]
        let fundamental:   Double = 432.0
        let baseDecay:     Double = 0.6        // per-second decay exponent multiplier
        let attackSamples: Int    = Int(0.025 * sampleRate)  // 25 ms
        let peakAmplitude: Double = 0.65
        let fadeStartSec:  Double = duration - 1.0
        let fadeStartSmp:  Int    = Int(fadeStartSec * sampleRate)
        let fadeDuration:  Double = 1.0

        // Reverb: 200 ms delay, 0.12 mix
        let reverbDelaySamples = Int(0.200 * sampleRate)
        let reverbMix: Double  = 0.12

        // Build raw float buffer
        var samples = [Double](repeating: 0.0, count: Int(frameCount))

        for i in 0 ..< Int(frameCount) {
            let t = Double(i) / sampleRate
            var v: Double = 0.0
            for p in partials {
                let freq   = fundamental * p.ratio
                let decay  = exp(-baseDecay * p.decayMult * t)
                v += p.weight * decay * sin(2.0 * .pi * freq * t)
            }
            samples[i] = v
        }

        // Attack ramp
        for i in 0 ..< min(attackSamples, samples.count) {
            let ramp = Double(i) / Double(attackSamples)
            samples[i] *= ramp
        }

        // Fade-out over last 1 s
        for i in fadeStartSmp ..< samples.count {
            let pos      = Double(i - fadeStartSmp) / (fadeDuration * sampleRate)
            let fadeGain = max(0.0, 1.0 - pos)
            samples[i]  *= fadeGain
        }

        // Reverb tail: mix delayed copy
        var reverbbed = samples
        for i in reverbDelaySamples ..< samples.count {
            reverbbed[i] += samples[i - reverbDelaySamples] * reverbMix
        }

        // Normalize to peakAmplitude after reverb — reverb tail can exceed pre-reverb peak,
        // so normalizing here guarantees no hard clip regardless of reverbMix.
        let maxRevAbs = reverbbed.map { abs($0) }.max() ?? 1.0
        if maxRevAbs > 0 {
            let scale = peakAmplitude / maxRevAbs
            for i in 0 ..< reverbbed.count { reverbbed[i] *= scale }
        }

        // Safety hard clip — should be a no-op after normalization above.
        for i in 0 ..< reverbbed.count {
            reverbbed[i] = max(-1.0, min(1.0, reverbbed[i]))
        }

        try writePCMSamples(reverbbed, frameCount: frameCount, format: format, to: url)
    }

    // MARK: - Failure bowl synthesis

    /// 5 sharp 800 Hz pings, 0.4 s each, 0.14 s apart, 5 ms attack, exp(-5*t) decay.
    private func writeFailureBowl(to url: URL) throws {
        let sampleRate: Double = 44100
        let duration: Double  = 3.0
        let frameCount        = AVAudioFrameCount(sampleRate * duration)

        let format = monoFormat()

        let pingFreq:      Double = 800.0
        let pingDuration:  Double = 0.4
        let pingSpacing:   Double = 0.14
        let attackSamples: Int    = Int(0.005 * sampleRate)  // 5 ms
        let decayRate:     Double = 5.0
        let peakAmp:       Double = 0.7
        let pingCount:     Int    = 5

        var samples = [Double](repeating: 0.0, count: Int(frameCount))

        for p in 0 ..< pingCount {
            let startSec    = Double(p) * pingSpacing
            let startSample = Int(startSec * sampleRate)
            let endSample   = min(Int((startSec + pingDuration) * sampleRate), samples.count)

            for i in startSample ..< endSample {
                let t    = Double(i - startSample) / sampleRate
                let env  = exp(-decayRate * t)
                let ramp: Double
                let rampIdx = i - startSample
                if rampIdx < attackSamples {
                    ramp = Double(rampIdx) / Double(attackSamples)
                } else {
                    ramp = 1.0
                }
                samples[i] += peakAmp * ramp * env * sin(2.0 * .pi * pingFreq * t)
            }
        }

        // Hard clip
        for i in 0 ..< samples.count {
            samples[i] = max(-1.0, min(1.0, samples[i]))
        }

        try writePCMSamples(samples, frameCount: frameCount, format: format, to: url)
    }

    // MARK: - PCM → AVAudioFile writer

    private func writePCMSamples(
        _ samples: [Double],
        frameCount: AVAudioFrameCount,
        format: AVAudioFormat,
        to url: URL
    ) throws {
        // We need a float32 buffer for AVAudioPCMBuffer, then convert to int16 when writing.
        // AVAudioFile with int16 format writes the WAV header automatically.
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw BowlAudioGeneratorError.formatCreationFailed
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frameCount) else {
            throw BowlAudioGeneratorError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            throw BowlAudioGeneratorError.bufferAllocationFailed
        }

        for i in 0 ..< Int(frameCount) {
            channelData[i] = Float(samples[i])
        }

        // Write as int16 WAV via AVAudioFile (handles WAVE header, bit-depth conversion)
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: wavSettings(sampleRate: format.sampleRate),
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try audioFile.write(from: buffer)
    }

    // MARK: - WAV settings dictionary

    private func wavSettings(sampleRate: Double) -> [String: Any] {
        return [
            AVFormatIDKey:            kAudioFormatLinearPCM,
            AVSampleRateKey:          sampleRate,
            AVNumberOfChannelsKey:    1,
            AVLinearPCMBitDepthKey:   16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey:    false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}

// MARK: - Errors

private enum BowlAudioGeneratorError: Error {
    case formatCreationFailed
    case bufferAllocationFailed
}
