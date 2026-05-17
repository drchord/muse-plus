import Foundation
import OSLog
import BackgroundTasks
import UIKit

// MARK: - Data structures

struct SessionSample: Codable {
    let time:   Double  // seconds from session start
    let alpha:  Float
    let theta:  Float
    let beta:   Float
    let delta:  Float
    let gamma:  Float
    let depth:  Float
    let inDeep: Bool
    // Build 65 additions — all Optional with defaults; decodeIfPresent for build 64 JSON back-compat.
    var heartRateBPM:       Float? = nil  // BPM; Optics-derived on Athena, legacy PPG on Muse S 2019
    var faa:                Float? = nil  // af8α - af7α; nil when either frontal channel is artifacted
    var aperiodicSlopeMean: Float? = nil  // IRASA mean χ across canonical EEG1-4; nil if R² < 0.85
    var iTPFFrontal:        Float? = nil  // Kalman-filtered frontal theta peak Hz; nil until reliable
    // Build 55b placeholders — nil until OpticsPipeline lands
    var hboL: Float? = nil
    var hboR: Float? = nil
    var hbrL: Float? = nil
    var hbrR: Float? = nil
    // Build 76 — HRV via AMPD on Optics7/8 (Athena only)
    var rmssd:      Float? = nil  // Root mean square of successive RR differences (ms)
    var lfhfRatio:  Float? = nil  // Sympatho-vagal balance: LF (0.04-0.15 Hz) / HF (0.15-0.40 Hz)
    // Build 77 — full pipeline state preservation. All Optional for back-compat.
    var meditationIndex:          Float? = nil  // raw frontal-mean idx (uncorrected)
    var meditationIndexCorrected: Float? = nil  // aperiodic-corrected idx (B77 scoring input)
    var depthZ:                   Float? = nil  // z-score post-clip [-3, +8]
    var ecdfDisplay:              Float? = nil  // personal ECDF rank [0, 1]
    var alphaRel:                 Float? = nil  // SDK relative alpha [0, 1]
    var thetaRel:                 Float? = nil
    var betaRel:                  Float? = nil
    var alphaScoreSDK:            Float? = nil  // SDK Elements session score [0, 1]
    var thetaScoreSDK:            Float? = nil
    var betaScoreSDK:             Float? = nil
    var phase:                    String? = nil  // "warmup" (first 300s) or "main"
    // Build 77.2 — AF7+AF8 contact quality at sample time; nil in pre-B77.2 sessions.
    // Distinguishes genuine depth state from contact-loss decay in offline analysis.
    var frontalGood:              Bool? = nil
    // B80 — diagnostic fields, all Optional for back-compat.
    var contactStateAF7:  Int?    = nil  // raw HSI per channel: 1=good, 2=mediocre, 4=bad
    var contactStateAF8:  Int?    = nil
    var contactStateTP9:  Int?    = nil
    var contactStateTP10: Int?    = nil
    var packetGapMs:      Float?  = nil  // ms since previous raw EEG packet (LivenessWatchdog)
    // rssi: Muse SDK (LibMuse iOS 6.x) does not expose BLE RSSI at app layer. Reserved.
    var rssi:             Int?    = nil  // BLE RSSI dBm — always nil (SDK limitation)
    var appState:         String? = nil  // "active" | "background" | "inactive"
    var batteryLevel:     Float?  = nil  // headband battery 0-1
    var phoneOrientation: String? = nil  // "portrait" | "landscape" | "faceUp" | "faceDown"
}

// MARK: - B80 Diagnostic structures

struct StallEvent: Codable {
    var time: Double   // seconds from session start
    var gap:  Double   // seconds since previous packet when stall was detected
}

/// Per-event diagnostic stream entry. Appended by Probe via recordEvent(kind:detail:).
struct SessionEvent: Codable {
    var time:   Double          // seconds from session start
    var kind:   String          // "disconnect","reconnect","stall","audio-interrupt","route-change","contact-loss-AF7","contact-restored-AF7","app-background","app-foreground","timer-expired","ble-drop","reconnect-grace-expired"
    var detail: String? = nil
}

/// Session-level diagnostic summary. Built by Probe.buildDiagnostics(endReason:).
struct SessionDiagnostics: Codable {
    var packetGapMean: Double
    var packetGapP95:  Double
    var packetGapMax:  Double
    var packetCount:   Int
    var disconnectCount:     Int
    var reconnectAttempts:   Int
    var audioInterruptions:  Int
    var routeChanges:        Int
    var contactStateChanges: [String: Int]
    var stallEvents:         [StallEvent]
    var endReason:           String
    var buildTag:            String
    var deviceModel:         String
    var iosVersion:          String
    var museModel:           String?  // "ms03" if Athena detected, nil otherwise
    // B83 — A/B/C/F headband-fit grade derived from FIT-event rate (allGood flips).
    // Surfaces in session summary; trains user awareness of fit quality.
    var contactQualityGrade: String? = nil
    // B83 — fit events per minute, used to derive grade. Persisted for transparency.
    // Renamed from `contactTransitionsPerMin` (misnamed prior to grade-metric correction).
    var fitEventsPerMin: Double? = nil
}

struct DeepEpisode: Codable {
    let enterTime: Double
    var exitTime:  Double?
    var duration:  Double? { exitTime.map { $0 - enterTime } }
}

struct SessionRecord: Codable, Identifiable {
    let id:        String
    let startDate: Date
    var endDate:   Date?
    var samples:   [SessionSample]
    var episodes:  [DeepEpisode]
    var fitEvents: [Double]   // seconds from start when contact was lost
    // Calibration baseline stored at session start — nil in sessions before Build 75.
    var calibrationIndexMean: Float? = nil
    var calibrationIndexStd:  Float? = nil
    // Build 77 — subjective tap-to-mark ground truth from user during session.
    var marks: [Mark]? = nil
    // Build version that wrote this record. Helps the ECDF rebootstrap exclude legacy data.
    var buildTag: String? = nil  // e.g. "B77+"
    // B80 resilience fields — optional, nil in pre-B80 sessions. Backward-compatible.
    var recoveredFromCrash: Bool? = nil          // synthesised from orphan NDJSON after crash
    var ndjsonStateLog:     [String]? = nil      // NDJSON state-transition summary (A: appState lines)
    // B80 structured diagnostic stream — Probe-populated.
    var diagnostics: SessionDiagnostics? = nil
    var eventStream: [SessionEvent]?    = nil
    // B88 — summary scalars for analysis scripts. Populated at endSession; nil in pre-B88.
    var durationSec:       Double? = nil    // total session length in seconds
    var summarySampleCount: Int?   = nil    // sample count at close
    var deepFraction:      Double? = nil    // fraction [0, 1] of session time spent in deep state
    // B91 — ECDF entry threshold active for this session; nil in pre-B91 records.
    var enterThresholdAtSession: Float? = nil
    // B94 — composite quality score 0-100: deep fraction (40) + ecdf smoothness (25) + contact quality (35). Nil in pre-B94 records.
    var qualityScore: Int? = nil
    // B96 — time-of-day bucket when session started. Enables depth stratification by time in TrendsView.
    var timeOfDay: String? = nil  // "early-morning" (<6), "morning" (6-12), "afternoon" (12-17), "evening" (17-21), "night" (≥21)
    // B96 — Pearson r between meditationIndexCorrected and ecdfDisplay (main phase).
    // r < 0.3 = signals uncorrelated → possible calibration drift. Nil if < 20 paired samples.
    var meditationIndexCorrelation: Float? = nil
    // B97 — RMSSD delta: mean RMSSD at ecdfDisplay ≥ 0.50 minus mean at ecdfDisplay < 0.25.
    // Positive = deeper states have higher HRV. Nil if either bucket has < 5 samples.
    var rmssdDepthDelta: Float? = nil
    // B99 — main-phase mean frontal band powers for cross-session trend tracking (p=.03 for beta).
    // Nil in pre-B99 sessions; derive from samples array if needed.
    var mainAlphaMean: Float? = nil
    var mainThetaMean: Float? = nil
    var mainBetaMean:  Float? = nil
    // B100 — warmup-phase mean FAA. Prospective predictor (r=-0.76, n=8). Nil if <30 valid samples.
    var warmupFAAMean: Float? = nil
    // B107 — signal-quality score independent of deep-gate binary.
    var physiologicalScore: Int? = nil
    // B107 — calibration-phase beta baseline for physiologicalScore betaZ computation.
    var calibrationBetaMean: Float? = nil
    var calibrationBetaStd:  Float? = nil
    // B107 — BLE resilience counters.
    var stallCount:        Int? = nil   // BLE interruptions >0s that triggered grace period
    var bleReconnectCount: Int? = nil   // successful reconnects during session
    // B107 — session-level HRV scalars for physiologicalScore and TrendsView.
    var rmssd:            Double? = nil   // mean RMSSD over main phase (ms)
    var calibrationRmssd: Double? = nil   // mean RMSSD during calibration window (ms)
    // B107 — Poincaré plot and SDNN scalars (Brennan 2002). Populated at session end via attachHRVScalars().
    var sdnn:      Double? = nil   // standard deviation of all RR intervals (ms)
    var sd1:       Double? = nil   // Poincaré short-axis SD (instantaneous beat-to-beat variability)
    var sd2:       Double? = nil   // Poincaré long-axis SD (continuous long-term variability)
    var dfaAlpha1: Double? = nil   // DFA α1 scaling exponent — populated by Task 10

    var durationMinutes: Double {
        guard let end = endDate else { return 0 }
        return end.timeIntervalSince(startDate) / 60
    }
    var deepMinutes: Double {
        episodes.compactMap(\.duration).reduce(0, +) / 60
    }
    var meanAlpha: Float { avg(samples.map(\.alpha)) }
    var meanTheta: Float { avg(samples.map(\.theta)) }
    var meanDepth: Float { avg(samples.map(\.depth)) }
    var peakDepth: Float { samples.map(\.depth).max() ?? 0 }

    private func avg(_ v: [Float]) -> Float {
        v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count)
    }
}

// MARK: - NDJSON helpers

private struct NDJSONHeader: Codable {
    var _type = "header"
    let id: String
    let startDate: String
    let calibrationIndexMean: Float?
    let calibrationIndexStd: Float?
    let buildTag: String
}

private struct NDJSONFooter: Codable {
    var _type = "footer"
    let endDate: String
    let episodeCount: Int
    let sampleCount: Int
    let endReason: String
    let qualityScore: Int?
    let timeOfDay: String?
    let rmssdDepthDelta: Float?
    let meditationIndexCorrelation: Float?
    let warmupFAAMean: Float?        // B100: warmup mean FAA; nil if <30 valid samples
    let mainBetaMean:  Float?        // B100: main-phase mean frontal beta
    let enterThresholdAtSession: Float?   // B107: entry threshold active for this session
    let physiologicalScore: Int?          // B107: signal-quality score independent of deep gate
    let stallCount:          Int?         // B107: BLE grace-period stalls
    let bleReconnectCount:   Int?         // B107: successful BLE reconnects
    let rmssd:               Double?      // B107: main-phase RMSSD (ms)
    let calibrationRmssd:    Double?      // B107: calibration-phase RMSSD baseline (ms)
    let dfaAlpha1:           Double?      // B107: DFA α1 short-range scaling exponent
}

private struct NDJSONAppState: Codable {
    var _type = "appState"
    let state: String   // "background" | "foreground"
    let time: String    // ISO8601
}

private struct NDJSONMark: Codable {
    var _type = "mark"
    let time: Double
    let markType: String    // MarkType.rawValue
    let displayScore: Float
    let depthZ: Float?
}

private struct NDJSONFit: Codable {
    var _type = "fit"
    let time: Double
    let hsi: [Double]?
    let allGood: Bool?
}

private struct NDJSONSample: Codable {
    var _type = "sample"
    let time: Double
    let alpha: Float
    let theta: Float
    let beta: Float
    let delta: Float
    let gamma: Float
    let depth: Float
    let inDeep: Bool
    let heartRateBPM: Float?
    let faa: Float?
    let aperiodicSlopeMean: Float?
    let iTPFFrontal: Float?
    let rmssd: Float?
    let lfhfRatio: Float?
    let meditationIndex: Float?
    let meditationIndexCorrected: Float?
    let depthZ: Float?
    let ecdfDisplay: Float?
    let alphaRel: Float?
    let thetaRel: Float?
    let betaRel: Float?
    let alphaScoreSDK: Float?
    let thetaScoreSDK: Float?
    let betaScoreSDK: Float?
    let phase: String?
    let frontalGood: Bool?
    // B83 — per-channel HSI from MuseClient retainer; preserves contact state at sample time.
    let contactStateAF7:  Int?
    let contactStateAF8:  Int?
    let contactStateTP9:  Int?
    let contactStateTP10: Int?
    let packetGapMs:      Float?
    let appState:         String?
}

// MARK: - B83 NDJSON event types — every claim about audio/contact/timer must trace to a logged metric.

private struct NDJSONEvent: Codable {
    var _type = "event"
    let time: Double
    let kind: String       // see SessionEvent.kind
    let detail: String?
}

private struct NDJSONAudioState: Codable {
    var _type = "audioState"
    let time: Double
    let trigger: String                // "playGong" | "playEnterDeep" | "periodic" | "endSession" | etc.
    let outputVolume: Float            // AVAudioSession.outputVolume [0,1]
    let category: String               // "playback" | "playAndRecord" | ...
    let mode: String                   // "default" | "spokenAudio" | ...
    let isOtherAudioPlaying: Bool
    let outputs: [String]              // ["builtInSpeaker"] | ["bluetoothA2DP"] | ...
    let chimeEngineRunning: Bool
    let chimeEnginePlayerPlaying: Bool
    let soundscapeEngineRunning: Bool
    let chimeVolumeSetting: Float
    let secondsSinceLastRouteChange: Int?
}

private struct NDJSONGongLifecycle: Codable {
    var _type = "gongLifecycle"
    let time: Double
    let phase: String                  // "scheduled" | "started" | "completed" | "failed"
    let source: String                 // "file:bowl_success.m4a" | "synth:432Hz" | "synth:fallback"
    let detail: String?
}

private struct NDJSONMainStall: Codable {
    var _type = "mainStall"
    let time: Double
    let deltaSec: Double               // measured stall duration
    let thermalState: String           // "nominal" | "fair" | "serious" | "critical"
    let appState: String               // "active" | "background" | "inactive"
    let topStack: String               // top 5 frames, " | "-joined, mangled
}

private struct NDJSONUIState: Codable {
    var _type = "uiState"
    let time: Double
    let trigger: String                // "periodic" | "render" | "touch"
    let timerHudRendered: Int          // monotonic counter from Probe
    let depthGaugeRendered: Int
    let chipViewRendered: Int
}

private struct NDJSONDenoiseStats: Codable {
    var _type = "denoiseStats"
    let time: Double
    let alphaPowerRatio: Float        // filtered/raw alpha power 8-12 Hz; ≈1.0 = preservation
    let spikeRmsReduction: Float      // RMS drop in flagged-spike bins
    let spikesRemoved: Int            // |coeff|>T at SWT level 1
    let potatoFlagged: Bool           // Riemannian Potato artifact verdict
    let potatoDistance: Float         // Mahalanobis-like distance in Riemannian metric
    let asrComponentsReplaced: Int    // # PCA components reconstructed
    let bypassReason: String?         // "buffer_warming" | "denoise_disabled" | nil if active
}

// MARK: - Recorder

/// Thread-safe NDJSON-streaming session recorder.
///
/// Architecture (B80):
///   • startSession() opens an NDJSON file handle immediately. Every sample/mark/fit event
///     is appended synchronously on a private serial queue. Crash leaves a valid NDJSON
///     with all data up to the last written line.
///   • A 60s periodic timer calls fsync to bound crash data loss.
///   • endSession() writes the footer, closes the handle, then synthesises the canonical
///     .json (existing format) for backward-compatibility with analysis scripts.
///   • App launch: CrashRecovery.shared.recoverOrphans() scans for NDJSON without .json.
///   • File protection: NDJSON handle opened with .completeFileProtectionUnlessOpen so
///     iOS can write to it while the device is locked (after first unlock post-boot).
///     See Apple Data Protection docs:
///     https://developer.apple.com/documentation/uikit/protecting_the_user_s_privacy/
///     encrypting_your_app_s_files#2817930
///
final class SessionRecorder: ObservableObject {
    static let shared = SessionRecorder()
    static let currentBuildTag = "B107"

    @Published var isRecording   = false
    @Published var savedSessions: [URL] = []

    // MARK: - Private state (all accessed only on queue)

    private let queue = DispatchQueue(label: "com.drchord.museplus.recorder", qos: .utility)
    private var current:       SessionRecord?
    private var lastDeepState  = false
    private var ndjsonHandle:  FileHandle?
    private var ndjsonURL:     URL?
    private var sampleCount    = 0          // tracks when to fsync (every 10 samples)
    private var flushTimer:    Timer?       // 60s periodic flush (A3)
    private var appStateBag:   [Any] = []   // NotificationCenter tokens (A4)
    // B96: gong events fire 1.5s after endSession closes the NDJSON. Buffer them separately
    // so they survive the isRecording=false guard and flush to the next session open or os_log.
    private var pendingGongEvents: [(phase: String, source: String, detail: String?)] = []

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Lifecycle

    func startSession(calibrationIndexMean: Float? = nil, calibrationIndexStd: Float? = nil) {
        queue.sync {
            guard !isRecording else { return }
            let now = Date()
            let id  = iso8601.string(from: now)

            let hour = Calendar.current.component(.hour, from: now)
            let tod: String
            switch hour {
            case 0..<6:   tod = "early-morning"
            case 6..<12:  tod = "morning"
            case 12..<17: tod = "afternoon"
            case 17..<21: tod = "evening"
            default:       tod = "night"
            }

            current = SessionRecord(
                id:        id,
                startDate: now, endDate: nil,
                samples: [], episodes: [], fitEvents: [],
                calibrationIndexMean: calibrationIndexMean,
                calibrationIndexStd:  calibrationIndexStd,
                marks: [],
                buildTag: SessionRecorder.currentBuildTag
            )
            current?.timeOfDay = tod
            lastDeepState = false
            sampleCount   = 0

            // Open NDJSON file handle
            openNDJSONHandle(id: id, now: now,
                             calibrationIndexMean: calibrationIndexMean,
                             calibrationIndexStd:  calibrationIndexStd)

            // B97: flush gong events buffered from the previous session's post-close window.
            // Must run AFTER openNDJSONHandle — appendLine() requires a live handle.
            // time = -1.0 marks these as prior-session records for offline analysis.
            if !pendingGongEvents.isEmpty {
                Telemetry.audio.notice("flushing \(self.pendingGongEvents.count, privacy: .public) pending gong events from prior session")
                for ev in pendingGongEvents {
                    let nd = NDJSONGongLifecycle(_type: "gongLifecycle", time: -1.0,
                                                  phase: ev.phase, source: ev.source,
                                                  detail: ev.detail)
                    appendLine(nd)
                }
                pendingGongEvents.removeAll()
            }

            DispatchQueue.main.async { self.isRecording = true }

            // A3: periodic flush timer — guarantees ≤60s of unwritten data on crash
            DispatchQueue.main.async {
                self.flushTimer?.invalidate()
                self.flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    self?.periodicFlush()
                }
                RunLoop.main.add(self.flushTimer!, forMode: .common)
            }

            // A4: app-state notifications
            setupAppStateObservers()
        }
    }

    /// Synchronous session end. Returns the completed SessionRecord so callers can populate
    /// the summary sheet without re-decoding from disk (which uses try? and silently discards
    /// any decode error, producing an empty record). Returns nil only if no session was active.
    /// The canonical .json is saved as a side effect; save failures are logged via Telemetry.
    @discardableResult
    func endSession(reason: String = "normal") -> SessionRecord? {
        return queue.sync { () -> SessionRecord? in
            guard isRecording, var rec = current else { return nil }
            DispatchQueue.main.async { self.isRecording = false }
            populateSessionBiomarkers(&rec, reason: reason)
            current       = nil
            lastDeepState = false
            sampleCount   = 0
            save(rec)
            return rec
        }
    }

    // Extracted from endSession to keep queue.sync closure small enough for Swift type-checker.
    // Must only be called from within the recorder serial queue.
    private func populateSessionBiomarkers(_ rec: inout SessionRecord, reason: String) {
        rec.endDate = Date()
        if lastDeepState && !rec.episodes.isEmpty {
            let t = rec.endDate!.timeIntervalSince(rec.startDate)
            rec.episodes[rec.episodes.count - 1].exitTime = t
        }

        let durSec: TimeInterval = (rec.endDate ?? Date()).timeIntervalSince(rec.startDate)
        rec.durationSec        = durSec
        rec.summarySampleCount = rec.samples.count
        rec.deepFraction       = durSec > 0 ? rec.deepMinutes * 60.0 / durSec : 0

        // B94 quality score: deep fraction (40) + ecdf smoothness (25) + contact (35).
        let mainSamples: [SessionSample] = rec.samples.filter { $0.phase == "main" }
        let ecdfVals: [Float]            = mainSamples.compactMap(\.ecdfDisplay)
        let deepFrac: Float              = Float(rec.deepFraction ?? 0)
        let deepScore: Float             = min(40.0, deepFrac / 0.70 * 40.0)

        let smoothScore: Float
        if ecdfVals.count > 1 {
            let mean: Float     = ecdfVals.reduce(0, +) / Float(ecdfVals.count)
            let variance: Float = ecdfVals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(ecdfVals.count)
            smoothScore         = max(0.0, (1.0 - sqrt(variance) / 0.25)) * 25.0
        } else {
            smoothScore = 0.0
        }

        let frontalGoodCount: Int = mainSamples.filter { $0.frontalGood == true }.count
        let frontalGoodFrac: Float = mainSamples.isEmpty ? 0.0
            : Float(frontalGoodCount) / Float(mainSamples.count)
        rec.qualityScore = Int((deepScore + smoothScore + frontalGoodFrac * 35.0).rounded())

        // B96 meditationIndex / ecdfDisplay Pearson correlation.
        let paired: [(Float, Float)] = mainSamples.compactMap { s -> (Float, Float)? in
            guard let mi = s.meditationIndexCorrected, let ec = s.ecdfDisplay else { return nil }
            return (mi, ec)
        }
        if paired.count >= 20 {
            let n: Float  = Float(paired.count)
            let xMean: Float = paired.map { $0.0 }.reduce(0, +) / n
            let yMean: Float = paired.map { $0.1 }.reduce(0, +) / n
            let num: Float   = paired.map { ($0.0 - xMean) * ($0.1 - yMean) }.reduce(0, +)
            let dX: Float    = sqrt(paired.map { ($0.0 - xMean) * ($0.0 - xMean) }.reduce(0, +))
            let dY: Float    = sqrt(paired.map { ($0.1 - yMean) * ($0.1 - yMean) }.reduce(0, +))
            let denom: Float = dX * dY
            if denom > 1e-6 { rec.meditationIndexCorrelation = num / denom }
        }

        // B99 rmssdDepthDelta.
        let highRMSSD: [Float] = rec.samples.filter { ($0.ecdfDisplay ?? 0) >= 0.50 }.compactMap(\.rmssd)
        let lowRMSSD:  [Float] = rec.samples.filter { ($0.ecdfDisplay ?? 1) <  0.25 }.compactMap(\.rmssd)
        Telemetry.recording.notice("rmssdDepthDelta buckets: high=\(highRMSSD.count, privacy: .public) low=\(lowRMSSD.count, privacy: .public)")
        if highRMSSD.count >= 5 && lowRMSSD.count >= 5 {
            rec.rmssdDepthDelta = highRMSSD.reduce(0, +) / Float(highRMSSD.count)
                                - lowRMSSD.reduce(0, +)  / Float(lowRMSSD.count)
        }

        // B99 main-phase band power means.
        if !mainSamples.isEmpty {
            let n: Float      = Float(mainSamples.count)
            rec.mainAlphaMean = mainSamples.map(\.alpha).reduce(0, +) / n
            rec.mainThetaMean = mainSamples.map(\.theta).reduce(0, +) / n
            rec.mainBetaMean  = mainSamples.map(\.beta).reduce(0, +)  / n
            let logBeta  = rec.mainBetaMean  ?? Float(0)
            let logAlpha = rec.mainAlphaMean ?? Float(0)
            Telemetry.recording.notice("mainBeta=\(logBeta, privacy: .public) mainAlpha=\(logAlpha, privacy: .public) n=\(mainSamples.count, privacy: .public)")
        }

        // B100 warmup FAA mean.
        let warmupFAASamples: [Float] = rec.samples.filter { $0.phase == "warmup" }.compactMap(\.faa).filter { $0 != 0 }
        if warmupFAASamples.count >= 30 {
            rec.warmupFAAMean = warmupFAASamples.reduce(0, +) / Float(warmupFAASamples.count)
            let logFAA = rec.warmupFAAMean ?? Float(0)
            Telemetry.recording.notice("warmupFAAMean=\(logFAA, privacy: .public) n=\(warmupFAASamples.count, privacy: .public)")
        }

        // B107 session-level RMSSD mean (main phase).
        let mainRMSSD: [Double] = rec.samples.filter { $0.phase == "main" }.compactMap { $0.rmssd.map { Double($0) } }.filter { $0 > 0 }
        if !mainRMSSD.isEmpty {
            rec.rmssd = mainRMSSD.reduce(0, +) / Double(mainRMSSD.count)
        }

        rec.physiologicalScore = Self.computePhysiologicalScore(rec: rec, frontalGoodFrac: frontalGoodFrac)

        appendFooter(rec: rec, reason: reason)
        closeNDJSONHandle()

        DispatchQueue.main.async { [self] in
            flushTimer?.invalidate()
            flushTimer = nil
        }
        tearDownAppStateObservers()

        let allZs: [Float] = rec.samples.compactMap { s -> Float? in
            guard s.phase == "main", let z = s.depthZ, z.isFinite else { return nil }
            return z
        }
        if !allZs.isEmpty { PersonalZDistribution.shared.ingestSession(zSamples: allZs) }

        logSessionGapStats(rec)
    }

    private func logSessionGapStats(_ rec: SessionRecord) {
        let times: [Double] = rec.samples.map(\.time)
        guard times.count > 1 else {
            Telemetry.recording.notice("session ended: samples=\(times.count, privacy: .public) (too few to compute gaps)")
            return
        }
        let gaps:   [Double] = zip(times, times.dropFirst()).map { $1 - $0 }
        let mean:   Double   = gaps.reduce(0.0, +) / Double(gaps.count)
        let sorted: [Double] = gaps.sorted()
        let p95:    Double   = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        let maxGap: Double   = sorted.last ?? 0
        Telemetry.recording.notice("session ended: samples=\(times.count, privacy: .public) duration=\(String(format: "%.1f", times.last ?? 0), privacy: .public)s gap_mean=\(String(format: "%.3f", mean), privacy: .public)s gap_p95=\(String(format: "%.3f", p95), privacy: .public)s gap_max=\(String(format: "%.3f", maxGap), privacy: .public)s")
    }

    // MARK: - Data ingestion

    func addSample(alpha: Float, theta: Float, beta: Float,
                   delta: Float, gamma: Float, depth: Float, inDeep: Bool,
                   heartRateBPM: Float? = nil, faa: Float? = nil,
                   aperiodicSlopeMean: Float? = nil, iTPFFrontal: Float? = nil,
                   rmssd: Float? = nil, lfhfRatio: Float? = nil,
                   meditationIndex: Float? = nil,
                   meditationIndexCorrected: Float? = nil,
                   depthZ: Float? = nil, ecdfDisplay: Float? = nil,
                   alphaRel: Float? = nil, thetaRel: Float? = nil, betaRel: Float? = nil,
                   alphaScoreSDK: Float? = nil, thetaScoreSDK: Float? = nil,
                   betaScoreSDK: Float? = nil, phase: String? = nil,
                   frontalGood: Bool? = nil,
                   // B80 diagnostic fields
                   contactStateAF7:  Int? = nil,
                   contactStateAF8:  Int? = nil,
                   contactStateTP9:  Int? = nil,
                   contactStateTP10: Int? = nil,
                   packetGapMs:      Float? = nil,
                   appState:         String? = nil,
                   batteryLevel:     Float? = nil,
                   phoneOrientation: String? = nil) {
        queue.sync {
            guard isRecording, var rec = current else { return }
            let t = Date().timeIntervalSince(rec.startDate)
            var sample = SessionSample(
                time: t, alpha: alpha, theta: theta, beta: beta,
                delta: delta, gamma: gamma, depth: depth, inDeep: inDeep,
                heartRateBPM: heartRateBPM, faa: faa,
                aperiodicSlopeMean: aperiodicSlopeMean, iTPFFrontal: iTPFFrontal
            )
            sample.rmssd     = rmssd
            sample.lfhfRatio = lfhfRatio
            sample.meditationIndex          = meditationIndex
            sample.meditationIndexCorrected = meditationIndexCorrected
            sample.depthZ        = depthZ
            sample.ecdfDisplay   = ecdfDisplay
            sample.alphaRel      = alphaRel
            sample.thetaRel      = thetaRel
            sample.betaRel       = betaRel
            sample.alphaScoreSDK = alphaScoreSDK
            sample.thetaScoreSDK = thetaScoreSDK
            sample.betaScoreSDK  = betaScoreSDK
            sample.phase         = phase
            sample.frontalGood   = frontalGood
            // B80 diagnostic fields
            sample.contactStateAF7  = contactStateAF7
            sample.contactStateAF8  = contactStateAF8
            sample.contactStateTP9  = contactStateTP9
            sample.contactStateTP10 = contactStateTP10
            sample.packetGapMs      = packetGapMs
            sample.rssi             = nil  // SDK limitation
            sample.appState         = appState
            sample.batteryLevel     = batteryLevel
            sample.phoneOrientation = phoneOrientation
            rec.samples.append(sample)
            if inDeep && !lastDeepState {
                rec.episodes.append(DeepEpisode(enterTime: t, exitTime: nil))
            } else if !inDeep && lastDeepState && !rec.episodes.isEmpty {
                rec.episodes[rec.episodes.count - 1].exitTime = t
            }
            lastDeepState = inDeep
            current       = rec

            // Append to NDJSON
            let ndSample = NDJSONSample(
                _type: "sample",
                time: t, alpha: alpha, theta: theta, beta: beta,
                delta: delta, gamma: gamma, depth: depth, inDeep: inDeep,
                heartRateBPM: heartRateBPM, faa: faa,
                aperiodicSlopeMean: aperiodicSlopeMean, iTPFFrontal: iTPFFrontal,
                rmssd: rmssd, lfhfRatio: lfhfRatio,
                meditationIndex: meditationIndex,
                meditationIndexCorrected: meditationIndexCorrected,
                depthZ: depthZ, ecdfDisplay: ecdfDisplay,
                alphaRel: alphaRel, thetaRel: thetaRel, betaRel: betaRel,
                alphaScoreSDK: alphaScoreSDK, thetaScoreSDK: thetaScoreSDK,
                betaScoreSDK: betaScoreSDK, phase: phase, frontalGood: frontalGood,
                // B83 — per-channel HSI + packet gap + app state, populated from Probe.
                contactStateAF7:  contactStateAF7,
                contactStateAF8:  contactStateAF8,
                contactStateTP9:  contactStateTP9,
                contactStateTP10: contactStateTP10,
                packetGapMs:      packetGapMs,
                appState:         appState
            )
            appendLine(ndSample)

            // A1: fsync every 10 samples — crash-safety vs I/O trade-off
            sampleCount += 1
            if sampleCount % 10 == 0 {
                ndjsonHandle?.synchronizeFile()
            }
        }
    }

    func addMark(_ mark: Mark) {
        queue.sync {
            guard isRecording, var rec = current else { return }
            if rec.marks == nil { rec.marks = [] }
            rec.marks?.append(mark)
            current = rec

            let nd = NDJSONMark(
                _type: "mark",
                time: mark.time,
                markType: mark.type.rawValue,
                displayScore: mark.displayScore,
                depthZ: mark.depthZ
            )
            appendLine(nd)
        }
    }

    func addFitEvent(hsi: [Double]? = nil, allGood: Bool? = nil) {
        queue.sync {
            guard isRecording, var rec = current else { return }
            let t = Date().timeIntervalSince(rec.startDate)
            rec.fitEvents.append(t)
            current = rec

            let nd = NDJSONFit(_type: "fit", time: t, hsi: hsi, allGood: allGood)
            appendLine(nd)
            // B83 — also append to event stream so all instrumentation flows through one channel.
            self.appendEventLocked(SessionEvent(time: t, kind: "fit", detail: nil))
        }
    }

    // MARK: - B83 instrumentation API
    //
    // Every audio/contact/timer/freeze claim must trace to a logged metric in NDJSON.
    // No more "I think the gong played" — gongLifecycle says it did or didn't.
    // No more "the app froze" — mainStall says how long.
    // No more "TP9 flickered" — per-sample contactStateTP9 + fit events disambiguate.

    /// Returns elapsed seconds since session start. Returns 0.0 when no session is recording.
    /// Safe to call from any thread.
    func currentSessionElapsed() -> Double {
        return queue.sync {
            guard let rec = current else { return 0.0 }
            return Date().timeIntervalSince(rec.startDate)
        }
    }

    /// Append a typed event to NDJSON immediately. Single canonical entry point —
    /// replaces the broken in-memory `sessionEvents` array that B80 wired but never
    /// populated. Call sites: BLE state, route change, audio interrupt, fit, app
    /// lifecycle, gong lifecycle, timer expired, depth gate transitions.
    func appendEvent(_ event: SessionEvent) {
        queue.async {
            self.appendEventLocked(event)
        }
    }

    private func appendEventLocked(_ event: SessionEvent) {
        guard isRecording else { return }
        let nd = NDJSONEvent(_type: "event", time: event.time, kind: event.kind, detail: event.detail)
        appendLine(nd)
    }

    /// Snapshot AVAudioSession + engine state. Called from EndGongPlayer + ChimeEngine
    /// scheduling sites + a 30s periodic timer in App. If we ever need to ask
    /// "was the gong actually heard?" again, this is the receipt.
    func appendAudioState(trigger: String,
                          outputVolume: Float,
                          category: String,
                          mode: String,
                          isOtherAudioPlaying: Bool,
                          outputs: [String],
                          chimeEngineRunning: Bool,
                          chimeEnginePlayerPlaying: Bool,
                          soundscapeEngineRunning: Bool,
                          chimeVolumeSetting: Float,
                          secondsSinceLastRouteChange: Int?) {
        queue.async {
            guard self.isRecording else { return }
            let t = self.currentSessionElapsedLocked()
            let nd = NDJSONAudioState(
                _type: "audioState", time: t, trigger: trigger,
                outputVolume: outputVolume, category: category, mode: mode,
                isOtherAudioPlaying: isOtherAudioPlaying, outputs: outputs,
                chimeEngineRunning: chimeEngineRunning,
                chimeEnginePlayerPlaying: chimeEnginePlayerPlaying,
                soundscapeEngineRunning: soundscapeEngineRunning,
                chimeVolumeSetting: chimeVolumeSetting,
                secondsSinceLastRouteChange: secondsSinceLastRouteChange
            )
            self.appendLine(nd)
        }
    }

    /// Gong delivery confirmation — every scheduled→started→completed transition.
    /// If `scheduled` lands but `completed` never does, the audio path is broken
    /// independent of speaker physics.
    func appendGongLifecycle(phase: String, source: String, detail: String? = nil) {
        queue.async {
            if self.isRecording {
                let t = self.currentSessionElapsedLocked()
                let nd = NDJSONGongLifecycle(_type: "gongLifecycle", time: t,
                                              phase: phase, source: source, detail: detail)
                self.appendLine(nd)
            } else {
                // B96: NDJSON closed by endSession; buffer for os_log and next-session flush.
                self.pendingGongEvents.append((phase: phase, source: source, detail: detail))
                Telemetry.audio.notice("gongLifecycle(post-session) phase=\(phase, privacy: .public) source=\(source, privacy: .public)")
            }
        }
    }

    /// Main-thread stall — fired by MainThreadStall.shared when its 1Hz heartbeat
    /// detects > 1.5s gap. Quantifies the "freezing" sensation users report.
    func appendMainStall(deltaSec: Double, thermalState: String, appState: String, topStack: String) {
        queue.async {
            guard self.isRecording else { return }
            let t = self.currentSessionElapsedLocked()
            let nd = NDJSONMainStall(_type: "mainStall", time: t,
                                      deltaSec: deltaSec, thermalState: thermalState,
                                      appState: appState, topStack: topStack)
            self.appendLine(nd)
        }
    }

    /// UI render counters — proves whether SwiftUI views actually invoked `body`.
    /// If user says "I didn't see the timer" and `timerHudRendered > 0`, that's a
    /// contrast/position problem (UI is showing). If `== 0`, it's a binding bug.
    func appendUIState(trigger: String,
                       timerHudRendered: Int,
                       depthGaugeRendered: Int,
                       chipViewRendered: Int) {
        queue.async {
            guard self.isRecording else { return }
            let t = self.currentSessionElapsedLocked()
            let nd = NDJSONUIState(_type: "uiState", time: t, trigger: trigger,
                                    timerHudRendered: timerHudRendered,
                                    depthGaugeRendered: depthGaugeRendered,
                                    chipViewRendered: chipViewRendered)
            self.appendLine(nd)
        }
    }

    /// Internal: queue-local elapsed time. Caller must already be on `queue`.
    private func currentSessionElapsedLocked() -> Double {
        guard let rec = current else { return 0.0 }
        return Date().timeIntervalSince(rec.startDate)
    }

    /// EEG denoising metrics — emitted once per 1-second window by EEGWindowBuffer.
    /// Cleaned signal is logged as a sidecar; raw EEG continues flowing through the
    /// real-time pipeline unchanged for B83. B84 may switch the live signal to cleaned
    /// once these metrics validate against tap-to-mark ground truth.
    func appendDenoiseStats(alphaPowerRatio: Float,
                            spikeRmsReduction: Float,
                            spikesRemoved: Int,
                            potatoFlagged: Bool,
                            potatoDistance: Float,
                            asrComponentsReplaced: Int,
                            bypassReason: String?) {
        queue.async {
            guard self.isRecording else { return }
            let t = self.currentSessionElapsedLocked()
            let nd = NDJSONDenoiseStats(
                _type: "denoiseStats", time: t,
                alphaPowerRatio: alphaPowerRatio,
                spikeRmsReduction: spikeRmsReduction,
                spikesRemoved: spikesRemoved,
                potatoFlagged: potatoFlagged,
                potatoDistance: potatoDistance,
                asrComponentsReplaced: asrComponentsReplaced,
                bypassReason: bypassReason
            )
            self.appendLine(nd)
        }
    }

    // MARK: - Storage

    func loadSavedSessions() {
        let dir  = sessionsDir()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ))?.filter { $0.pathExtension == "json" }
          .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        DispatchQueue.main.async { self.savedSessions = urls }
    }

    func deleteSession(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        // Also remove matching NDJSON if present
        let ndjson = url.deletingPathExtension().appendingPathExtension("ndjson")
        try? FileManager.default.removeItem(at: ndjson)
        loadSavedSessions()
    }

    // MARK: - Private: NDJSON file management

    private func openNDJSONHandle(id: String, now: Date,
                                  calibrationIndexMean: Float?,
                                  calibrationIndexStd: Float?) {
        let dir = sessionsDir()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmm"
        let baseName = "session_\(fmt.string(from: now))"
        let url = dir.appendingPathComponent("\(baseName).ndjson")
        ndjsonURL = url

        // Create file with .completeFileProtectionUnlessOpen data protection.
        // This class allows reads/writes while the device is locked (after first unlock
        // since boot), unlike .completeFileProtection which blocks all access when locked.
        // Apple Data Protection docs:
        // https://developer.apple.com/documentation/uikit/protecting_the_user_s_privacy/
        // encrypting_your_app_s_files
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )

        guard let handle = try? FileHandle(forWritingTo: url) else {
            Telemetry.recording.error("NDJSON open failed: \(url.lastPathComponent, privacy: .public)")
            return
        }
        ndjsonHandle = handle

        // Write header line
        let header = NDJSONHeader(
            _type: "header",
            id: id,
            startDate: iso8601.string(from: now),
            calibrationIndexMean: calibrationIndexMean,
            calibrationIndexStd:  calibrationIndexStd,
            buildTag: SessionRecorder.currentBuildTag
        )
        appendLine(header)
        Telemetry.recording.notice("NDJSON opened: \(url.lastPathComponent, privacy: .public)")
    }

    private func appendLine<T: Encodable>(_ value: T) {
        guard let handle = ndjsonHandle else { return }
        do {
            var data = try enc.encode(value)
            data.append(contentsOf: [0x0A]) // newline '\n'
            handle.write(data)
        } catch {
            Telemetry.recording.error("NDJSON encode error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // betaZ (0-50) + rmssdResponse (0-30) + signalCoherence (0-20) = 0-100
    // Extracted from endSession closure to avoid Swift type-checker timeout on large closures.
    private static func computePhysiologicalScore(rec: SessionRecord, frontalGoodFrac: Float) -> Int {
        let betaZScore: Float
        if let calBeta = rec.calibrationBetaMean,
           let calBetaStd = rec.calibrationBetaStd,
           let sessBeta = rec.mainBetaMean,
           calBetaStd > 0 {
            let bz = (calBeta - sessBeta) / max(calBetaStd, 0.10)
            betaZScore = min(max(bz / 2.0 * 50.0, 0.0), 50.0)
        } else {
            betaZScore = 0.0
        }
        let rmssdScore: Float
        if let sessRmssd = rec.rmssd,
           let calRmssd = rec.calibrationRmssd,
           calRmssd > 1.0 {
            let response = (sessRmssd - calRmssd) / calRmssd
            // 25% RMSSD improvement = full 30 pts; realistic session range 5-25%.
            // Prior scaling (×30 raw) required 100% improvement to score max — physiologically impossible.
            rmssdScore = Float(min(max(response / 0.25 * 30.0, 0.0), 30.0))
        } else {
            rmssdScore = 0.0
        }
        let coherenceScore = frontalGoodFrac * 20.0
        return Int((betaZScore + rmssdScore + coherenceScore).rounded())
    }

    private func appendFooter(rec: SessionRecord, reason: String) {
        let footer = NDJSONFooter(
            _type: "footer",
            endDate:    iso8601.string(from: rec.endDate ?? Date()),
            episodeCount: rec.episodes.count,
            sampleCount:  rec.samples.count,
            endReason:    reason,
            qualityScore: rec.qualityScore,
            timeOfDay:    rec.timeOfDay,
            rmssdDepthDelta: rec.rmssdDepthDelta,
            meditationIndexCorrelation: rec.meditationIndexCorrelation,
            warmupFAAMean: rec.warmupFAAMean,
            mainBetaMean:  rec.mainBetaMean,
            enterThresholdAtSession: rec.enterThresholdAtSession,
            physiologicalScore: rec.physiologicalScore,
            stallCount:         rec.stallCount,
            bleReconnectCount:  rec.bleReconnectCount,
            rmssd:              rec.rmssd,
            calibrationRmssd:   rec.calibrationRmssd,
            dfaAlpha1:          rec.dfaAlpha1
        )
        appendLine(footer)
        ndjsonHandle?.synchronizeFile()
        Telemetry.recording.notice("NDJSON footer written: samples=\(rec.samples.count, privacy: .public) quality=\(rec.qualityScore.map(String.init) ?? "nil", privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func closeNDJSONHandle() {
        try? ndjsonHandle?.close()
        ndjsonHandle = nil
    }

    // MARK: - Private: 60s periodic flush (A3)

    private func periodicFlush() {
        queue.async {
            self.ndjsonHandle?.synchronizeFile()
            Telemetry.recording.notice("periodic fsync: sampleCount=\(self.sampleCount, privacy: .public)")
        }
    }

    // MARK: - Private: App state observers (A4)

    private func setupAppStateObservers() {
        let nc = NotificationCenter.default
        let resign = nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.appendAppState("background")
            self?.queue.async { self?.ndjsonHandle?.synchronizeFile() }
        }
        let resume = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.appendAppState("foreground")
        }
        appStateBag = [resign, resume]
    }

    private func tearDownAppStateObservers() {
        let nc = NotificationCenter.default
        appStateBag.forEach { nc.removeObserver($0) }
        appStateBag = []
    }

    private func appendAppState(_ state: String) {
        queue.async {
            let event = NDJSONAppState(
                _type: "appState",
                state: state,
                time:  self.iso8601.string(from: Date())
            )
            self.appendLine(event)
            Telemetry.recording.notice("appState=\(state, privacy: .public)")
        }
    }

    // MARK: - Private: canonical .json synthesis

    @discardableResult
    private func save(_ rec: SessionRecord) -> URL? {
        let dir = sessionsDir()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmm"
        let name = "session_\(fmt.string(from: rec.startDate)).json"
        let url  = dir.appendingPathComponent(name)

        let jsonEnc = JSONEncoder()
        jsonEnc.dateEncodingStrategy = .iso8601
        jsonEnc.outputFormatting     = .prettyPrinted

        do {
            let data = try jsonEnc.encode(rec)
            // B96: NSFileCoordinator signals iCloud daemon (ubiquityd) to pause syncing
            // this file during the write, preventing conflict copies ("session (1).json").
            // .forReplacing = we intend to replace any existing file atomically.
            var writeError: Error?
            var coordError: NSError?
            let coord = NSFileCoordinator()
            coord.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writingURL in
                do {
                    try data.write(to: writingURL, options: [.atomic, .completeFileProtection])
                } catch {
                    writeError = error
                }
            }
            if let err = coordError ?? writeError {
                throw err
            }
            loadSavedSessions()
            Telemetry.recording.notice("saved \(data.count, privacy: .public) B to \(name, privacy: .public)")
            // B98: verify round-trip decode to surface the silent JSONDecoder error that caused
            // Duration:0s in B97 sessions. Uses already-encoded data — no disk re-read needed.
            let verifyData = data
            let verifyName = name
            DispatchQueue.global(qos: .background).async {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                do {
                    _ = try dec.decode(SessionRecord.self, from: verifyData)
                    Telemetry.recording.notice("decode-verify OK: \(verifyName, privacy: .public)")
                } catch {
                    Telemetry.recording.error("decode-verify FAILED for \(verifyName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return url
        } catch {
            Telemetry.recording.error("SAVE FAILED for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Internal: synthesise .json from NDJSON (used by CrashRecovery)

    /// Parse an NDJSON file and return a SessionRecord. Returns nil if the file is
    /// unparseable or contains too few samples to be meaningful (< 2 samples).
    static func synthesiseRecord(from ndjsonURL: URL) -> SessionRecord? {
        guard let content = try? String(contentsOf: ndjsonURL, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let dec = JSONDecoder()
        var header:    NDJSONHeader?
        var samples:   [SessionSample] = []
        var episodes:  [DeepEpisode]   = []
        var fitEvents: [Double]        = []
        var marks:     [Mark]          = []
        var lastTime:  Double          = 0
        var footerEndDate: Date?
        var lastDeep = false
        var eventLog: [String]         = []
        var enterThresholdFromNDJSON: Float? = nil

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["_type"] as? String else { continue }

            switch type {
            case "header":
                header = try? dec.decode(NDJSONHeader.self, from: data)

            case "sample":
                if let s = try? dec.decode(NDJSONSample.self, from: data) {
                    var sample = SessionSample(
                        time: s.time, alpha: s.alpha, theta: s.theta, beta: s.beta,
                        delta: s.delta, gamma: s.gamma, depth: s.depth, inDeep: s.inDeep,
                        heartRateBPM: s.heartRateBPM, faa: s.faa,
                        aperiodicSlopeMean: s.aperiodicSlopeMean, iTPFFrontal: s.iTPFFrontal
                    )
                    sample.rmssd     = s.rmssd
                    sample.lfhfRatio = s.lfhfRatio
                    sample.meditationIndex          = s.meditationIndex
                    sample.meditationIndexCorrected = s.meditationIndexCorrected
                    sample.depthZ        = s.depthZ
                    sample.ecdfDisplay   = s.ecdfDisplay
                    sample.alphaRel      = s.alphaRel
                    sample.thetaRel      = s.thetaRel
                    sample.betaRel       = s.betaRel
                    sample.alphaScoreSDK = s.alphaScoreSDK
                    sample.thetaScoreSDK = s.thetaScoreSDK
                    sample.betaScoreSDK  = s.betaScoreSDK
                    sample.phase         = s.phase
                    sample.frontalGood   = s.frontalGood
                    samples.append(sample)

                    // Reconstruct episodes
                    if s.inDeep && !lastDeep {
                        episodes.append(DeepEpisode(enterTime: s.time, exitTime: nil))
                    } else if !s.inDeep && lastDeep && !episodes.isEmpty {
                        episodes[episodes.count - 1].exitTime = s.time
                    }
                    lastDeep = s.inDeep
                    lastTime = s.time
                }

            case "fit":
                if let t = obj["time"] as? Double { fitEvents.append(t) }

            case "mark":
                if let t         = obj["time"] as? Double,
                   let typeStr   = obj["markType"] as? String,
                   let markType  = MarkType(rawValue: typeStr),
                   let score     = obj["displayScore"] as? Double {
                    let depthZ   = obj["depthZ"] as? Float
                    marks.append(Mark(time: t, type: markType,
                                      displayScore: Float(score), depthZ: depthZ))
                }

            case "footer":
                if let endStr = obj["endDate"] as? String {
                    let fmt = ISO8601DateFormatter()
                    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    footerEndDate = fmt.date(from: endStr)
                }

            case "threshold":
                if let t = obj["enterThreshold"] as? Double {
                    enterThresholdFromNDJSON = Float(t)
                }

            case "appState":
                if let state = obj["state"] as? String,
                   let time  = obj["time"] as? String {
                    eventLog.append("\(state)@\(time)")
                }

            default: break
            }
        }

        guard let hdr = header, samples.count >= 2 else { return nil }

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let startDate = isoFmt.date(from: hdr.startDate) else { return nil }

        // Close any open episode
        if lastDeep && !episodes.isEmpty {
            episodes[episodes.count - 1].exitTime = lastTime
        }

        // endDate: use footer value, else synthesise from last sample + 1s
        let endDate = footerEndDate ?? startDate.addingTimeInterval(lastTime + 1)

        // Compute summary scalars from samples (mirrors endSession logic — ensures
        // crash-recovered sessions have analysis-ready fields, not nil stubs).
        // Use lastTime (last sample timestamp) not endDate — endDate for crash sessions
        // has a fabricated +1s padding that would overstate durationSec.
        let mainSamples    = samples.filter { $0.phase == "main" }
        let synthDuration  = footerEndDate != nil
            ? endDate.timeIntervalSince(startDate)
            : lastTime   // crash session: duration = last recorded sample, no padding
        let synthDeepFraction: Double? = mainSamples.isEmpty ? nil
            : Double(mainSamples.filter { $0.inDeep == true }.count) / Double(mainSamples.count)
        let synthQuality: Int? = {
            guard !mainSamples.isEmpty else { return nil }
            let deepFrac  = synthDeepFraction ?? 0.0
            let ecdfVals  = mainSamples.compactMap { $0.ecdfDisplay }
            let contactOK = Double(mainSamples.filter { $0.frontalGood == true }.count) / Double(mainSamples.count)
            guard !ecdfVals.isEmpty else { return nil }
            let n        = Float(ecdfVals.count)
            let mean     = ecdfVals.reduce(Float(0), +) / n
            let variance = ecdfVals.map { ($0 - mean) * ($0 - mean) }.reduce(Float(0), +) / n
            let std      = variance.squareRoot()
            let deepPts    = min(40.0, 40.0 * (deepFrac / 0.7))
            let smoothPts  = min(25.0, 25.0 * Double(max(Float(0), 1.0 - std / 0.25)))
            let contactPts = min(35.0, 35.0 * contactOK)
            return Int((deepPts + smoothPts + contactPts).rounded())
        }()

        return SessionRecord(
            id:        hdr.id,
            startDate: startDate,
            endDate:   endDate,
            samples:   samples,
            episodes:  episodes,
            fitEvents: fitEvents,
            calibrationIndexMean: hdr.calibrationIndexMean,
            calibrationIndexStd:  hdr.calibrationIndexStd,
            marks:    marks.isEmpty ? nil : marks,
            buildTag: hdr.buildTag,
            recoveredFromCrash: footerEndDate == nil ? true : nil,
            ndjsonStateLog: eventLog.isEmpty ? nil : eventLog,
            diagnostics: nil,
            eventStream: nil,
            durationSec:          synthDuration,
            summarySampleCount:   samples.count,
            deepFraction:         synthDeepFraction,
            enterThresholdAtSession: enterThresholdFromNDJSON,
            qualityScore:         synthQuality
        )
    }

    // MARK: - Directory

    private func sessionsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("MuseSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Internal accessor for CrashRecovery
    static func sessionsDirURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("MuseSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - BGTask registration (A4 background flush)
// Called once at app startup before the first BGTask is submitted.
// Identifier must match Info.plist BGTaskSchedulerPermittedIdentifiers entry.

extension SessionRecorder {
    static let bgFlushIdentifier = "com.drchord.museplus.session-flush"

    /// Register the BGProcessingTask handler. Call from App init before WindowGroup renders.
    static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: bgFlushIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // fsync the active NDJSON handle if a session is in progress
            SessionRecorder.shared.queue.sync {
                SessionRecorder.shared.ndjsonHandle?.synchronizeFile()
                Telemetry.recording.notice("BGProcessingTask flush completed")
            }
            processingTask.setTaskCompleted(success: true)
            // Schedule next flush ~5 min from now
            SessionRecorder.scheduleNextBackgroundFlush()
        }
    }

    /// Submit a BGProcessingTaskRequest. Safe to call when no session is active —
    /// the registered handler will no-op the fsync if ndjsonHandle is nil.
    static func scheduleNextBackgroundFlush() {
        let request = BGProcessingTaskRequest(identifier: bgFlushIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)  // ≥5 min
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower       = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Telemetry.recording.notice("BGProcessingTask scheduled")
        } catch {
            // BGTaskScheduler returns errors in simulator — safe to ignore in non-device builds
            Telemetry.recording.error("BGProcessingTask schedule error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - B80 Diagnostic attachment (C)

    func attachDiagnostics(_ diag: SessionDiagnostics) {
        queue.sync {
            guard isRecording else { return }
            current?.diagnostics = diag
            Telemetry.recording.notice("diagnostics attached: packets=\(diag.packetCount, privacy: .public) disconnects=\(diag.disconnectCount, privacy: .public) stalls=\(diag.stallEvents.count, privacy: .public) endReason=\(diag.endReason, privacy: .public)")
        }
    }

    func attachEventStream(_ events: [SessionEvent]) {
        queue.sync {
            guard isRecording else { return }
            current?.eventStream = events
            Telemetry.recording.notice("eventStream attached: \(events.count, privacy: .public) events")
        }
    }

    func attachEnterThreshold(_ threshold: Float) {
        queue.sync {
            guard isRecording, let rec = current else { return }
            current?.enterThresholdAtSession = threshold
            struct NDJSONThreshold: Codable {
                var _type = "threshold"
                let time: Double
                let enterThreshold: Float
            }
            let t = Date().timeIntervalSince(rec.startDate)
            appendLine(NDJSONThreshold(time: t, enterThreshold: threshold))
        }
    }

    func attachCalibrationBeta(mean: Float, std: Float) {
        queue.sync {
            guard isRecording else { return }
            current?.calibrationBetaMean = mean
            current?.calibrationBetaStd  = std
            Telemetry.recording.notice("calibrationBeta attached: mean=\(mean, privacy: .public) std=\(std, privacy: .public)")
        }
    }

    func attachCalibrationRmssd(_ rmssd: Double) {
        queue.sync {
            guard self.isRecording else { return }
            self.current?.calibrationRmssd = rmssd
            Telemetry.recording.notice("calibrationRmssd=\(rmssd, privacy: .public) ms")
        }
    }

    // B107: attach Poincaré / SDNN scalars captured at session end from HRVPipeline.latestX properties.
    func attachHRVScalars(sdnn: Double, sd1: Double, sd2: Double?) {
        queue.sync {
            guard self.isRecording else { return }
            self.current?.sdnn = sdnn
            self.current?.sd1  = sd1
            self.current?.sd2  = sd2
            Telemetry.recording.notice("HRVScalars attached: sdnn=\(sdnn, privacy: .public) sd1=\(sd1, privacy: .public) sd2=\(sd2.map { String($0) } ?? "nil", privacy: .public)")
        }
    }

    func attachDFAAlpha1(_ alpha: Double) {
        queue.sync {
            guard self.isRecording else { return }
            self.current?.dfaAlpha1 = alpha
            Telemetry.recording.notice("dfaAlpha1=\(alpha, privacy: .public)")
        }
    }

    // MARK: - B107 BLE resilience counters

    func recordBLEStall() {
        queue.sync {
            guard self.isRecording, var rec = self.current else { return }
            rec.stallCount = (rec.stallCount ?? 0) + 1
            self.current = rec
        }
    }

    func recordBLEReconnect() {
        queue.sync {
            guard self.isRecording, var rec = self.current else { return }
            rec.bleReconnectCount = (rec.bleReconnectCount ?? 0) + 1
            self.current = rec
        }
    }

    // MARK: - B80 Gap marker (B)

    /// Records a BLE-drop gap in the session timeline. Called by Probe when grace-period
    /// reconnect closes the gap or when grace expires. Appends a 'gap' line to NDJSON.
    func recordGap(reason: String, durationSec: Double) {
        queue.sync {
            guard isRecording, let rec = current else { return }
            let t = Date().timeIntervalSince(rec.startDate)
            Telemetry.recording.notice("gap reason=\(reason, privacy: .public) duration=\(String(format: "%.1f", durationSec), privacy: .public)s at t=\(String(format: "%.1f", t), privacy: .public)s")
            // Append a typed line to NDJSON for offline analysis.
            struct NDJSONGap: Codable {
                var _type = "gap"
                let time: Double
                let reason: String
                let durationSec: Double
            }
            appendLine(NDJSONGap(time: t, reason: reason, durationSec: durationSec))
        }
    }
}
