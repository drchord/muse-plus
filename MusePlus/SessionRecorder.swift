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
    // B117 — count of HR samples rejected by absolute bounds gate [35, 120 BPM].
    var hrSamplesRejected: Int? = nil
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
    // B137: buildTag from the previous session. Not persisted (transient — for post-session
    // narrative only). Nil on first-ever session or crash-recovered records.
    var previousBuildTag: String? = nil
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
    // B94 — composite quality score 0-100. B129 formula: deep fraction (30) + approach zone (10) + ecdf smoothness (25) + contact quality (35). Nil in pre-B94 records.
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
    // B109 — score sub-components for post-session audit (betaZ 0-50, rmssd 0-30, coherence 0-20).
    var betaZScore:     Int? = nil
    var rmssdScore:     Int? = nil
    var coherenceScore: Int? = nil
    // B107 — calibration-phase beta baseline for physiologicalScore betaZ computation.
    var calibrationBetaMean: Float? = nil
    var calibrationBetaStd:  Float? = nil
    // B117 F4 — true when attachCalibrationBeta got real values (not DepthScore defaults 0.0/0.30).
    var calibrationBetaAttached: Bool? = nil
    // B117 F6 — FAA sign convention literal for this session ("af8-af7").
    var faaConvention: String? = nil
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
    // B122: unclipped beta z-score and signal quality / spectral fields.
    var betaZRaw:          Float? = nil
    var signalQualityMeanSpikes:      Float? = nil
    var signalQualityAlphaPowerRatio: Float? = nil
    var potatoFlaggedPct:       Float? = nil
    // B132: potato flag rate split by phase. Warmup = first 300s, main = remainder.
    var warmupPotatoFlaggedPct: Float? = nil
    var mainPotatoFlaggedPct:   Float? = nil
    var alphaRelMean: Float? = nil
    var thetaRelMean: Float? = nil
    var betaRelMean:  Float? = nil
    var ecdfMax:      Float? = nil
    var ecdfP90:      Float? = nil
    // B126: sustained-window requirement active for this session. Nil in pre-B126 records.
    var enterSustainedAtSession: Int? = nil
    // B126: alpha-theta ratio summary. Nil in pre-B126 records.
    var alphaThetaMean:              Float?  = nil
    var alphaThetaCrossoverCount:    Int?    = nil
    var alphaThetaCrossoverFirstTime: Double? = nil
    // B129: aperiodic slope drift — lateMainChiMean minus warmupChiMean. Positive = slope steepened
    // (typical during deep absorption). >|0.3| triggers telemetry notice. Nil if <5 chi samples.
    var chiDrift: Float? = nil
    // B132: mean aperiodic slope during warmup phase (first 300s). Key predictor for calibIM.
    // Nil if warmup has <5 samples with valid aperiodicSlopeMean. More negative = lower arousal at start.
    var warmupAperiodicSlopeMean: Float? = nil
    // B135: composite readiness score 0–6 from the three top warmup predictors of deep-state entry.
    // warmupFAAMean(<-0.15=2,<0=1,≥0=0) + warmupAperiodicSlopeMean(≥-1.25=2,≥-1.35=1,<-1.35=0)
    // + calibrationIndexMean(<-0.30=2,<-0.10=1,≥-0.10=0). Nil unless ALL three inputs are present
    // (missing input ≠ unfavorable input; partial scoring would misrepresent one available indicator
    // as a low composite). ≥5=primed, 3–4=mixed, ≤2=low-readiness. n=10 basis — revisit at n=20.
    var readinessScore: Int? = nil
    // B137: session-mean LF/HF ratio over main phase. Lower = more parasympathetic (relaxed).
    // Typical meditation target < 1.5. Nil if fewer than 10 main-phase lfhfRatio samples available.
    var lfhfMean: Double? = nil

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

// B117 — calibration completion record. Emitted ONCE at the warmup→main transition
// after DepthScore.forceFinalize() has populated real baseline values. Lets analysis
// tooling verify whether calibrationBetaMean was real or a default (0.0/0.30).
private struct NDJSONCalibrationSummary: Codable {
    var _type = "calibrationSummary"
    let time: Double
    let calibrationIndexMean: Float?
    let calibrationIndexStd: Float?
    let calibrationBetaMean: Float?
    let calibrationBetaStd: Float?
    let calibrationSampleCount: Int?
    let calibrationDurationSec: Double?
}

// B117 — C5 coach event log. Unified record of every coaching intervention
// (chime, speech, haptic, breath pacer, banner) with the EEG/HRV state at trigger time.
// Required for post-hoc A/B evaluation of coaching efficacy.
struct CoachStateSnapshot: Codable {
    let ecdfDisplay: Float?
    let beta: Float?
    let alpha: Float?
    let theta: Float?
    let faa: Float?
    let heartRateBPM: Float?
}
private struct NDJSONCoach: Codable {
    var _type = "coach"
    let time: Double
    let trigger: String        // e.g. "induction-stall-360", "approach-zone", "enter-deep", "return-nudge"
    let diagnosis: String?     // optional context: "no-deep", "left-frontal-arousal", etc.
    let intervention: String   // "chime" | "speech" | "haptic" | "breath-pacer" | "approach-bowl" | "return-bowl" | "banner" | mixed e.g. "chime+speech"
    let speechText: String?    // verbatim TTS string, nil if no speech
    let stateAtTrigger: CoachStateSnapshot
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
    let betaZScore:    Int?               // B109: beta suppression component (0-50)
    let rmssdScore:    Int?               // B109: HRV response component (0-30)
    let coherenceScore: Int?              // B109: frontal coherence component (0-20)
    let stallCount:          Int?         // B107: BLE grace-period stalls
    let bleReconnectCount:   Int?         // B107: successful BLE reconnects
    let rmssd:               Double?      // B107: main-phase RMSSD (ms)
    let calibrationRmssd:    Double?      // B107: calibration-phase RMSSD baseline (ms)
    let dfaAlpha1:           Double?      // B107: DFA α1 short-range scaling exponent
    // B120: Poincaré / SDNN scalars — previously only in SessionRecord, lost on crash recovery.
    let sdnn: Double?       // standard deviation of all RR intervals (ms)
    let sd1:  Double?       // Poincaré short-axis SD (instantaneous beat-to-beat variability)
    let sd2:  Double?       // Poincaré long-axis SD (continuous long-term variability)
    // B108: calibration-phase beta baseline — exported so betaZScore inputs are verifiable from JSON.
    let calibrationBetaMean: Float?
    let calibrationBetaStd:  Float?
    // B108: calibration ECDF index — leading predictor of session outcome (r²=0.84, n=8, treat as signal not gate).
    let calibrationIndexMean: Float?
    // B117 F4: true if attachCalibrationBeta received non-default values; false if it wrote 0.0/0.30 defaults.
    // betaZScore=0 is meaningless when attached=false; betaZScore=0 with attached=true is a real measurement.
    let calibrationBetaAttached: Bool?
    // B117 F6: literal label for the FAA sign convention used in this session.
    // "af8-af7" means faa = af8Alpha - af7Alpha (right minus left). Empirically (Muse++ n=8)
    // NEGATIVE faa predicts depth for this user (r=-0.76 with deepFraction).
    let faaConvention: String?
    // B122: raw unclipped bz before clamping to [0,50]. betaZScore loses discrimination above bz=2;
    // betaZRaw preserves longitudinal magnitude (e.g. bz=5.1 vs bz=2.1 are both score=50).
    let betaZRaw:          Float?
    // B122: denoise pipeline quality summary — surfaced in JSON so post-session analysis
    // does not require parsing NDJSON denoiseStats records.
    let signalQualityMeanSpikes:      Float?   // mean spikesRemoved/frame; >15 = elevated artifact
    let signalQualityAlphaPowerRatio: Float?   // mean alphaPowerRatio; <0.70 = alpha degraded by noise
    let potatoFlaggedPct:        Float?    // fraction of frames with Riemannian Potato verdict
    let warmupPotatoFlaggedPct:  Float?    // B132: potato rate during warmup (t<300s)
    let mainPotatoFlaggedPct:    Float?    // B132: potato rate during main phase (t>=300s)
    // B122: calibration-independent relative band power for main phase.
    // alphaRel+thetaRel+betaRel+... sum to 1; robust to absolute amplitude shifts from artifact.
    let alphaRelMean: Float?
    let thetaRelMean: Float?
    let betaRelMean:  Float?
    // B122: ecdf peak diagnostics. inDeep gate fires at ecdfDisplay>=0.70 sustained 10s.
    // ecdfMax shows whether the gate was ever approached; ecdfP90 is robust to single-sample spikes.
    let ecdfMax: Float?
    let ecdfP90: Float?
    // B126: sustained-window requirement active for this session (4-20 windows × 0.5s = 2s-10s).
    // Adapts session-over-session via EnterSustainedShaping. nil in pre-B126 records.
    let enterSustainedAtSession: Int?
    // B126: alpha-theta ratio summary. mean(alpha−theta) across all calibrated windows; negative = theta-dominant.
    let alphaThetaMean:              Float?
    let alphaThetaCrossoverCount:    Int?     // windows where theta > alpha
    let alphaThetaCrossoverFirstTime: Double? // seconds from session start to first crossover; nil if none
    // B129: aperiodic slope drift (lateMainChiMean - warmupChiMean). Nil if <5 chi samples in either window.
    let chiDrift: Float?
    // B132: mean aperiodic slope during warmup phase (first 300s). Nil if <5 valid warmup chi samples.
    let warmupAperiodicSlopeMean: Float?
    // B135: composite readiness score 0–6. Nil unless all three source inputs are present.
    let readinessScore: Int?
    // B137: main-phase mean LF/HF ratio. Nil if <10 valid main-phase samples.
    let lfhfMean: Double?
    // B117 F9: one-line formulas for every exported metric. Self-documenting telemetry.
    let metricDefinitions: [String: String]?
}

private struct NDJSONAppState: Codable {
    var _type = "appState"
    let state: String   // "background" | "foreground"
    let time: String    // ISO8601
}

private struct NDJSONGateEvent: Codable {
    var _type = "gateEvent"
    let time:     Double   // session elapsed seconds; -1.0 if gate fired before session start
    let path:     String   // "cleared" | "timeout"
    let tp9Tier:  Int
    let tp10Tier: Int
}

private struct NDJSONDriftAlert: Codable {
    var _type = "driftAlert"
    let time:        Double   // session elapsed seconds
    let posterior:   Float    // BOCPD posterior at alert
    let ecdfAtAlert: Float    // smoothedDisplay at alert
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
    static let currentBuildTag: String = {
        let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return v.isEmpty ? "Bunknown" : "B\(v)"
    }()

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
    // B122: gate events fire before session start (at connect time). Buffer so they flush to
    // NDJSON at session open. path="cleared"|"timeout"; time will be written as -1.0 (pre-session).
    private var pendingGateEvents: [(path: String, tp9Tier: Int, tp10Tier: Int)] = []
    // B122: denoise quality accumulators — all accessed on queue, reset per-session.
    private var denoiseSpikesSum:          Double = 0
    private var denoiseAlphaPowerSum:      Double = 0
    private var denoiseFrameCount:         Int    = 0
    private var denoisePotatoes:           Int    = 0
    // B132: phase-split potato counters (warmup = t<300s, main = t>=300s).
    private var warmupDenoiseFrameCount:   Int    = 0
    private var warmupDenoisePotatoes:     Int    = 0
    private var mainDenoiseFrameCount:     Int    = 0
    private var mainDenoisePotatoes:       Int    = 0

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
            // B117 F6 — declare the FAA sign convention used by DepthScore. Footer exports this.
            current?.faaConvention = "af8-af7"
            lastDeepState      = false
            sampleCount        = 0
            // B122: reset denoise accumulators for the new session
            denoiseSpikesSum          = 0
            denoiseAlphaPowerSum      = 0
            denoiseFrameCount         = 0
            denoisePotatoes           = 0
            // B132: reset phase-split potato accumulators
            warmupDenoiseFrameCount   = 0
            warmupDenoisePotatoes     = 0
            mainDenoiseFrameCount     = 0
            mainDenoisePotatoes       = 0

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

            // B122: flush gate events buffered before this session opened (gate fires at connect,
            // session opens later). time=-1.0 marks pre-session origin, matching pendingGongEvents.
            if !pendingGateEvents.isEmpty {
                Telemetry.recording.notice("flushing \(self.pendingGateEvents.count, privacy: .public) pending gate events from pre-session")
                for ev in pendingGateEvents {
                    let nd = NDJSONGateEvent(_type: "gateEvent", time: -1.0,
                                             path: ev.path, tp9Tier: ev.tp9Tier, tp10Tier: ev.tp10Tier)
                    appendLine(nd)
                }
                pendingGateEvents.removeAll()
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
    // ⚠️ RECURRING BUG (B132, B135, both caught by CI): accessing rec.<field> directly inside a
    // Telemetry.recording.notice("...\(rec.field, privacy:...)") string interpolation inside this
    // function causes "escaping autoclosure captures inout parameter" compile error.
    // FIX: extract to a local `let` BEFORE the Telemetry call. Never pass rec.field directly.
    private func populateSessionBiomarkers(_ rec: inout SessionRecord, reason: String) {
        // Capture before writing so the caveat fires correctly on build upgrades.
        rec.previousBuildTag = UserDefaults.standard.string(forKey: "lastSessionBuildTag")
        rec.endDate = Date()
        if lastDeepState && !rec.episodes.isEmpty {
            let t = rec.endDate!.timeIntervalSince(rec.startDate)
            rec.episodes[rec.episodes.count - 1].exitTime = t
        }

        let durSec: TimeInterval = (rec.endDate ?? Date()).timeIntervalSince(rec.startDate)
        rec.durationSec        = durSec
        rec.summarySampleCount = rec.samples.count
        rec.deepFraction       = durSec > 0 ? rec.deepMinutes * 60.0 / durSec : 0

        // B129 quality score: deep fraction (30) + approach zone (10) + ecdf smoothness (25) + contact (35).
        // deepScore reduced 40→30; approachScore rewards time near the gate even without entry.
        // Approach zone: ecdfDisplay ∈ [0.5×threshold, threshold). Full 10pts at 30% of session in zone.
        let mainSamples: [SessionSample] = rec.samples.filter { $0.phase == "main" }
        let ecdfVals: [Float]            = mainSamples.compactMap(\.ecdfDisplay)
        let deepFrac: Float              = Float(rec.deepFraction ?? 0)
        let deepScore: Float             = min(30.0, deepFrac / 0.70 * 30.0)

        let thresh: Float      = rec.enterThresholdAtSession ?? 0.70
        let halfThresh: Float  = 0.5 * thresh
        let approachCount      = ecdfVals.filter { $0 >= halfThresh && $0 < thresh }.count
        let approachFrac: Float = ecdfVals.isEmpty ? 0 : Float(approachCount) / Float(ecdfVals.count)
        let approachScore: Float = min(10.0, approachFrac / 0.30 * 10.0)

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
        rec.qualityScore = Int((deepScore + approachScore + smoothScore + frontalGoodFrac * 35.0).rounded())

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

        // B129: aperiodic slope drift — warmup chi vs late-main chi. Positive = slope steepened.
        let warmupChiVals: [Float]   = rec.samples.filter { $0.phase == "warmup" }.compactMap(\.aperiodicSlopeMean)
        let mainChiVals:   [Float]   = mainSamples.compactMap(\.aperiodicSlopeMean)
        let lateMainChiVals: [Float] = mainChiVals.count >= 10 ? Array(mainChiVals.suffix(120)) : mainChiVals
        if warmupChiVals.count >= 5 && lateMainChiVals.count >= 5 {
            let earlyMean = warmupChiVals.reduce(0, +) / Float(warmupChiVals.count)
            let lateMean  = lateMainChiVals.reduce(0, +) / Float(lateMainChiVals.count)
            let drift     = lateMean - earlyMean
            rec.chiDrift  = drift
            if abs(drift) > 0.3 {
                Telemetry.recording.notice("chiDrift=\(drift, privacy: .public) earlyMean=\(earlyMean, privacy: .public) lateMean=\(lateMean, privacy: .public) — aperiodic slope shifted during session")
            }
        }

        // B132: warmup aperiodic slope mean — mean chi over first 300s warmup samples.
        if warmupChiVals.count >= 5 {
            let wam = warmupChiVals.reduce(0, +) / Float(warmupChiVals.count)
            rec.warmupAperiodicSlopeMean = wam
            Telemetry.recording.notice("warmupAperiodicSlopeMean=\(wam, privacy: .public) n=\(warmupChiVals.count, privacy: .public)")
        }

        // B100 warmup FAA mean.
        // Note: faa==0 is filtered as artifact (SDK returns 0 when AF7/AF8 below quality threshold,
        // not genuine bilateral symmetry). Revisit if SDK behaviour changes.
        let warmupFAASamples: [Float] = rec.samples.filter { $0.phase == "warmup" }.compactMap(\.faa).filter { $0 != 0 }
        if warmupFAASamples.count >= 30 {
            rec.warmupFAAMean = warmupFAASamples.reduce(0, +) / Float(warmupFAASamples.count)
            let logFAA = rec.warmupFAAMean ?? Float(0)
            Telemetry.recording.notice("warmupFAAMean=\(logFAA, privacy: .public) n=\(warmupFAASamples.count, privacy: .public)")
        }

        // B135: readiness score — composite of the three empirically validated warmup predictors.
        // Runs AFTER warmupFAAMean (B100) and warmupAperiodicSlopeMean (B132) are populated above.
        // Based on n=10 sessions (Jun 1–10 2026). Thresholds provisional; revisit at n=20.
        let faaPoints: Int = {
            guard let f = rec.warmupFAAMean else { return 0 }
            if f < -0.15 { return 2 }
            if f <  0.00 { return 1 }
            return 0
        }()
        let slopePoints: Int = {
            guard let s = rec.warmupAperiodicSlopeMean else { return 0 }
            if s >= -1.25 { return 2 }
            if s >= -1.35 { return 1 }
            return 0
        }()
        let calibPoints: Int = {
            guard let c = rec.calibrationIndexMean else { return 0 }
            if c < -0.30 { return 2 }
            if c < -0.10 { return 1 }
            return 0
        }()
        // Require ALL three inputs: missing input (nil) ≠ unfavorable input (0 pts).
        // With ||, a session with only calibIM available scores 0+0+calibPoints, which reads as
        // "Low" when really two components were unmeasured. Use && so missing = nil badge not 0/6.
        if rec.warmupFAAMean != nil, rec.warmupAperiodicSlopeMean != nil, rec.calibrationIndexMean != nil {
            rec.readinessScore = faaPoints + slopePoints + calibPoints
        }
        let logRS = rec.readinessScore.map(String.init) ?? "nil"
        Telemetry.recording.notice("readinessScore=\(logRS, privacy: .public) faa=\(faaPoints, privacy: .public) slope=\(slopePoints, privacy: .public) calibIM=\(calibPoints, privacy: .public)")

        // B107 session-level RMSSD mean (main phase).
        let mainRMSSD: [Double] = rec.samples.filter { $0.phase == "main" }.compactMap { $0.rmssd.map { Double($0) } }.filter { $0 > 0 }
        if !mainRMSSD.isEmpty {
            rec.rmssd = mainRMSSD.reduce(0, +) / Double(mainRMSSD.count)
        }

        // B137: session-mean LF/HF ratio (main phase). Requires ≥10 samples for stability.
        let mainLFHF: [Double] = rec.samples.filter { $0.phase == "main" }.compactMap { $0.lfhfRatio.map { Double($0) } }.filter { $0 > 0 }
        if mainLFHF.count >= 10 {
            rec.lfhfMean = mainLFHF.reduce(0, +) / Double(mainLFHF.count)
        }

        let scoreComponents = Self.computePhysiologicalScore(rec: rec, frontalGoodFrac: frontalGoodFrac)
        rec.physiologicalScore = scoreComponents.total
        rec.betaZScore         = scoreComponents.betaZ
        rec.rmssdScore         = scoreComponents.rmssd
        rec.coherenceScore     = scoreComponents.coherence

        // B122: betaZRaw — same formula as betaZScore but without clamping. Preserves magnitude
        // above bz=2 where the clamped score saturates at 50 (e.g. bz=5.1 → score=50, raw=5.1).
        if let calBeta = rec.calibrationBetaMean,
           let calBetaStd = rec.calibrationBetaStd,
           let sessBeta = rec.mainBetaMean,
           calBetaStd >= 0 {
            rec.betaZRaw = (calBeta - sessBeta) / max(calBetaStd, 0.10)
        }

        // B122: calibration-independent relative band power (main phase).
        // These sum to ~1.0 within each sample, so absolute amplitude shifts from artifact
        // or device variance cancel out.
        if !mainSamples.isEmpty {
            let alphaRels = mainSamples.compactMap(\.alphaRel)
            let thetaRels = mainSamples.compactMap(\.thetaRel)
            let betaRels  = mainSamples.compactMap(\.betaRel)
            if !alphaRels.isEmpty { rec.alphaRelMean = alphaRels.reduce(0, +) / Float(alphaRels.count) }
            if !thetaRels.isEmpty { rec.thetaRelMean = thetaRels.reduce(0, +) / Float(thetaRels.count) }
            if !betaRels.isEmpty  { rec.betaRelMean  = betaRels.reduce(0, +)  / Float(betaRels.count)  }
        }

        // B122: main-phase ecdfDisplay peak and p90. Scoped to phase=="main" so warmup
        // spikes don't inflate ecdfMax — inDeep fires only during main phase.
        // Threshold is adaptive: 0.55 (0 sessions) → 0.60 (<5) → 0.65 (<20) → 0.70 (≥20).
        // kEnterSustained default = 20 windows × 0.5s = 10s; tunable 6–24 via UserDefaults.
        let mainEcdfVals = rec.samples.filter { $0.phase == "main" }.compactMap(\.ecdfDisplay).sorted()
        if !mainEcdfVals.isEmpty {
            rec.ecdfMax = mainEcdfVals.last
            let p90idx  = max(0, Int(Double(mainEcdfVals.count) * 0.90) - 1)
            rec.ecdfP90 = mainEcdfVals[p90idx]
        }

        // B122: denoise quality from per-frame accumulators. Exclude bypass frames (buffer_warming
        // etc.) — only frames where the denoiser was active are informative.
        if denoiseFrameCount > 0 {
            rec.signalQualityMeanSpikes      = Float(denoiseSpikesSum / Double(denoiseFrameCount))
            rec.signalQualityAlphaPowerRatio = Float(denoiseAlphaPowerSum / Double(denoiseFrameCount))
            rec.potatoFlaggedPct             = Float(denoisePotatoes) / Float(denoiseFrameCount)
        }
        // B132: phase-split potato rates.
        if warmupDenoiseFrameCount > 0 {
            rec.warmupPotatoFlaggedPct = Float(warmupDenoisePotatoes) / Float(warmupDenoiseFrameCount)
        }
        if mainDenoiseFrameCount > 0 {
            rec.mainPotatoFlaggedPct = Float(mainDenoisePotatoes) / Float(mainDenoiseFrameCount)
        }

        appendFooter(rec: rec, reason: reason)
        if let tag = rec.buildTag {
            UserDefaults.standard.set(tag, forKey: "lastSessionBuildTag")
        }
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
            // B122: accumulate for footer summary (computed in populateSessionBiomarkers)
            if bypassReason == nil {
                self.denoiseSpikesSum     += Double(spikesRemoved)
                self.denoiseAlphaPowerSum += Double(alphaPowerRatio)
                self.denoiseFrameCount    += 1
                if potatoFlagged { self.denoisePotatoes += 1 }
                // B132: split by warmup (t<300s) vs main phase.
                if t < 300 {
                    self.warmupDenoiseFrameCount += 1
                    if potatoFlagged { self.warmupDenoisePotatoes += 1 }
                } else {
                    self.mainDenoiseFrameCount += 1
                    if potatoFlagged { self.mainDenoisePotatoes += 1 }
                }
            }
        }
    }

    // B122: gate event — written to NDJSON when temporal gate clears or times out.
    // Internal access (same MusePlus module; App.swift calls via SessionRecorder.shared).
    // If called before session start, the event is buffered in pendingGateEvents and
    // flushed at the next startSession() (time=-1.0 marks pre-session origin).
    func appendGateEvent(path: String, tp9Tier: Int, tp10Tier: Int) {
        queue.async {
            Telemetry.recording.notice("B122 gateEvent: path=\(path, privacy: .public) tp9=\(tp9Tier, privacy: .public) tp10=\(tp10Tier, privacy: .public)")
            if self.isRecording {
                let t = self.currentSessionElapsedLocked()
                let nd = NDJSONGateEvent(_type: "gateEvent", time: t,
                                         path: path, tp9Tier: tp9Tier, tp10Tier: tp10Tier)
                self.appendLine(nd)
            } else {
                self.pendingGateEvents.append((path: path, tp9Tier: tp9Tier, tp10Tier: tp10Tier))
            }
        }
    }

    // B126: drift alert event — written to NDJSON when BOCPD detects downward drift in deep state.
    // Uses queue.async + current != nil guard (mirrors appendGateEvent pattern).
    // Only fires while inDeepState (enforced by DepthGate call site).
    func appendDriftAlert(time: Double, posterior: Float, ecdfAtAlert: Float) {
        queue.async { [weak self] in
            guard let self, self.current != nil else { return }
            let ev = NDJSONDriftAlert(time: time, posterior: posterior, ecdfAtAlert: ecdfAtAlert)
            self.appendLine(ev)
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
    private static func computePhysiologicalScore(rec: SessionRecord, frontalGoodFrac: Float) -> (total: Int, betaZ: Int, rmssd: Int, coherence: Int) {
        let betaZScore: Float
        if let calBeta = rec.calibrationBetaMean,
           let calBetaStd = rec.calibrationBetaStd,
           let sessBeta = rec.mainBetaMean,
           calBetaStd >= 0 {
            let bz = (calBeta - sessBeta) / max(calBetaStd, 0.10)
            betaZScore = min(max(bz / 2.0 * 50.0, 0.0), 50.0)
        } else {
            betaZScore = 0.0
        }
        let rmssdScore: Float
        if let sessRmssd = rec.rmssd {
            // B108: absolute RMSSD scoring replaces relative-to-calibration formula.
            // Root cause of B107 score=0: (sessRmssd=81ms - calRmssd=97ms) / calRmssd = -0.17 → clamped to 0.
            // Failure mode: calibration captures arousal spike at session start; relaxation during
            // meditation then LOWERS RMSSD from the elevated baseline, which the old formula read as
            // "no HRV improvement." Absolute thresholds are calibration-independent.
            // Reference bands: Shaffer & Ginsberg (2017). Capped at 30pts.
            // <40ms → 0-10pts, 40-65ms → 10-25pts, 65-100ms → 25-30pts, >100ms → 30pts.
            let sr = Float(sessRmssd)
            rmssdScore = sr < 40  ? max(0, sr / 40.0 * 10.0)
                       : sr < 65  ? 10.0 + (sr - 40.0) / 25.0 * 15.0
                       :             min(30.0, 25.0 + (sr - 65.0) / 35.0 * 5.0)
        } else {
            rmssdScore = 0.0
        }
        let coherenceScore = frontalGoodFrac * 20.0
        return (
            total:    Int((betaZScore + rmssdScore + coherenceScore).rounded()),
            betaZ:    Int(betaZScore.rounded()),
            rmssd:    Int(rmssdScore.rounded()),
            coherence: Int(coherenceScore.rounded())
        )
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
            betaZScore:         rec.betaZScore,
            rmssdScore:         rec.rmssdScore,
            coherenceScore:     rec.coherenceScore,
            stallCount:         rec.stallCount,
            bleReconnectCount:  rec.bleReconnectCount,
            rmssd:              rec.rmssd,
            calibrationRmssd:   rec.calibrationRmssd,
            dfaAlpha1:           rec.dfaAlpha1,
            sdnn:                rec.sdnn,
            sd1:                 rec.sd1,
            sd2:                 rec.sd2,
            calibrationBetaMean: rec.calibrationBetaMean,
            calibrationBetaStd:  rec.calibrationBetaStd,
            calibrationIndexMean: rec.calibrationIndexMean,
            calibrationBetaAttached: rec.calibrationBetaAttached,
            faaConvention: rec.faaConvention ?? "af8-af7",
            betaZRaw:          rec.betaZRaw,
            signalQualityMeanSpikes:      rec.signalQualityMeanSpikes,
            signalQualityAlphaPowerRatio: rec.signalQualityAlphaPowerRatio,
            potatoFlaggedPct:           rec.potatoFlaggedPct,
            warmupPotatoFlaggedPct:     rec.warmupPotatoFlaggedPct,
            mainPotatoFlaggedPct:       rec.mainPotatoFlaggedPct,
            alphaRelMean:      rec.alphaRelMean,
            thetaRelMean:      rec.thetaRelMean,
            betaRelMean:       rec.betaRelMean,
            ecdfMax:                 rec.ecdfMax,
            ecdfP90:                 rec.ecdfP90,
            enterSustainedAtSession: rec.enterSustainedAtSession,
            alphaThetaMean:              rec.alphaThetaMean,
            alphaThetaCrossoverCount:    rec.alphaThetaCrossoverCount,
            alphaThetaCrossoverFirstTime: rec.alphaThetaCrossoverFirstTime,
            chiDrift:                    rec.chiDrift,
            warmupAperiodicSlopeMean:    rec.warmupAperiodicSlopeMean,
            readinessScore:              rec.readinessScore,
            lfhfMean:                    rec.lfhfMean,
            metricDefinitions:           SessionRecorder.metricDefinitions
        )
        appendLine(footer)
        ndjsonHandle?.synchronizeFile()
        Telemetry.recording.notice("NDJSON footer written: samples=\(rec.samples.count, privacy: .public) quality=\(rec.qualityScore.map(String.init) ?? "nil", privacy: .public) reason=\(reason, privacy: .public)")
    }

    // B117 F9 — one-line formula for every metric exported in the footer or sample stream.
    // Static so that the dictionary is constructed once and serialized identically every session.
    // If a formula changes, update both here AND the implementation. Do not let these drift.
    // Formulas verified against the actual implementation files cited (B117).
    // If implementation changes, update BOTH the code and this dict — analysis tooling reads this.
    // Entries marked SOURCE=... cite the file:line where the formula lives in code.
    // Entries marked PARTIAL/UNVERIFIED admit incomplete grounding — fix in B118.
    static let metricDefinitions: [String: String] = [
        "faa": "af8Alpha - af7Alpha on frontal channels (right-minus-left log10 µV²). SOURCE=Pipeline/DepthScore.swift:~83. Empirically (n=16 sessions) NEGATIVE faa predicts depth: r(FAA,depthZ)=-0.43, r(FAA,deepFraction)=-0.48 (direction consistent, p≈0.10, NOT significant at p<0.05). Original B117 claim r=-0.76 was overstated from n=8 early sessions.",
        "ecdfDisplay": "smoothedDisplay = Kalman-filtered Personal-ECDF mapping of depthZ to [0,1]. SOURCE=Audio/DepthGate.swift:~162 (smoothedDisplay = kalmanDepth).",
        "depthZ": "max(-3.0, min(8.0, (idx - baselineMean) / max(baselineStd, 0.01))) where idx is aperiodic-corrected meditationIndex (or raw if correction disabled). SOURCE=Pipeline/DepthScore.swift:~119.",
        "meditationIndex": "0.7*((alpha + theta) - 2*beta) + 0.3*max(0, theta - alpha) on log10 µV² band powers. Peniston alpha-theta crossover term added. SOURCE=Muse/MuseTypes.swift:~44.",
        "meditationIndexCorrected": "Same formula as meditationIndex but on aperiodic-corrected band powers (FOOOF-style 1/f subtracted); equals raw when chi unavailable. SOURCE=Pipeline/AperiodicCorrection.swift.",
        "betaZScore": "bz = (calibrationBetaMean - mainBetaMean) / max(calibrationBetaStd, 0.10); score = clamp(bz/2.0*50, 0, 50). Meaningless unless calibrationBetaAttached=true. SOURCE=SessionRecorder.swift:~1013.",
        "rmssdScore": "Piecewise ABSOLUTE thresholds (B108+): sr<40→sr/40*10; 40≤sr<65→10+(sr-40)/25*15; 65≤sr<100→min(30,25+(sr-65)/35*5); sr≥100→30. Calibration-INDEPENDENT (was relative pre-B108). SOURCE=SessionRecorder.swift:~1018-1033.",
        "coherenceScore": "Contact quality (NOT EEG coherence): frontalGoodFrac × 20.0, where frontalGoodFrac = fraction of main-phase samples with frontalGood=true (AF7+AF8 electrode contact flag). Legacy misnomer — JSON key preserved for backwards compatibility. SOURCE=SessionRecorder.swift:~1034.",
        "physiologicalScore": "Int(round(betaZScore + rmssdScore + coherenceScore)); range 0-100. SOURCE=SessionRecorder.swift:~1036.",
        "rmssdDepthDelta": "mean RMSSD at ecdfDisplay>=0.50 minus mean at ecdfDisplay<0.25 (ms). Positive = HRV rises during depth. nil if either bucket <5 samples. SOURCE=B97 spec.",
        "dfaAlpha1": "Detrended Fluctuation Analysis short-range scaling exponent. ~1.0=healthy pink-noise resting; ->0.5=random walk (may indicate artifact); >1.2=Brownian. SOURCE=Pipeline/HRVPipeline.swift computeDFAAlpha1.",
        "sdnn": "Standard deviation of all NN/RR intervals over the recording window (ms).",
        "sd1": "Poincaré short-axis SD ≈ instantaneous beat-to-beat variability. SD1>SD2 at rest is non-physiological (Brennan 2002) and suggests PPG noise or ectopics.",
        "sd2": "Poincaré long-axis SD ≈ continuous long-term variability. Healthy resting: SD2>SD1.",
        "iTPFFrontal": "Individual Theta Peak Frequency on frontal channels (Hz). SOURCE=Pipeline/ITPFTracker.swift.",
        "aperiodicSlopeMean": "1/f aperiodic exponent χ from log-log PSD fit (Donoghue 2020 / FOOOF). Steeper (more negative) = stronger long-range power decay. SOURCE=Pipeline/AperiodicSlope.swift.",
        "alphaPowerRatio": "cleanAlpha / rawAlpha from EEGDenoiser (post-denoise 8-12 Hz / pre-denoise); ≈1.0 = preservation. SOURCE=Pipeline/EEGDenoiser.swift:~849.",
        "warmupFAAMean": "mean of faa across warmup phase; requires >=30 valid samples or nil.",
        "mainBetaMean": "z-scored frontal beta averaged across main phase (post-warmup).",
        "mainAlphaMean": "z-scored frontal alpha averaged across main phase.",
        "mainThetaMean": "z-scored frontal theta averaged across main phase.",
        "calibrationBetaMean": "mean frontal beta over calibration samples (DepthScore samples appended when calibrationProgress >= 0.5). SOURCE=Pipeline/DepthScore.swift:~95.",
        "calibrationBetaStd": "max(0.10, sqrt(var)) of frontal beta over calibration samples; floored at 0.10. SOURCE=Pipeline/DepthScore.swift:~163.",
        "calibrationIndexMean": "median of meditationIndex over calibration samples (robust to outliers). SOURCE=Pipeline/DepthScore.swift:~137.",
        "calibrationIndexStd": "max(MAD*1.4826, 0.10) over calibration samples; consistent-Gaussian-σ estimate. SOURCE=Pipeline/DepthScore.swift:~149.",
        "calibrationRmssd": "mean RMSSD computed over calibration-window RR intervals (ms).",
        "qualityScore": "deep fraction (30) + approach zone (10) + ecdf smoothness (25) + contact quality (35); 0-100. Approach zone = fraction of main-phase samples with ecdfDisplay ∈ [0.5×threshold, threshold); full 10pts at 30% of session in zone. SOURCE=B129.",
        "deepFraction": "fraction of session time where gate.inDeepState==true; [0,1].",
        "enterThresholdAtSession": "ecdfDisplay threshold required to enter deep state (default 0.65).",
        "fitEventsPerMin": "count of contact-state allGood flips per minute; lower=better.",
        "hrSamplesRejected": "count of raw heartRateBPM samples rejected by B117 absolute bounds gate [35,120]. nil if no samples rejected.",
        "betaZRaw": "Unclipped beta z-score: (calibrationBetaMean - mainBetaMean) / max(calibrationBetaStd, 0.10). betaZScore clamps at bz=2 (score=50); betaZRaw shows true magnitude for longitudinal tracking. B122.",
        "signalQualityMeanSpikes": "Mean spikesRemoved per active denoiseStats frame. >15 = elevated artifact load (muscle/motion/EMF). Baseline B120=5.9, B118=9.2. B122.",
        "signalQualityAlphaPowerRatio": "Mean alpha power preservation ratio after ASR denoising (cleanAlpha/rawAlpha 8-12 Hz). 1.0 = perfect; <0.70 = significant alpha degradation. B122.",
        "potatoFlaggedPct": "Fraction of active denoiseStats frames where Riemannian Potato declared severe artifact. B122.",
        "warmupPotatoFlaggedPct": "Riemannian Potato artifact rate during warmup phase (t<300s). High warmup rate = movement/setup artifact; less predictive of session quality than main phase. SOURCE=SessionRecorder.swift appendDenoiseStats B132.",
        "mainPotatoFlaggedPct": "Riemannian Potato artifact rate during main phase (t>=300s). High main-phase rate = mid-session signal degradation (headband slip, movement). Stronger predictor of session quality than session-wide potatoFlaggedPct. SOURCE=SessionRecorder.swift appendDenoiseStats B132.",
        "warmupAperiodicSlopeMean": "Mean 1/f aperiodic slope χ over warmup phase (first 300s). More negative = steeper slope = lower arousal baseline at session start. Leading predictor candidate for calibrationIndexMean. nil if <5 warmup samples have valid χ. SOURCE=SessionRecorder.swift populateSessionBiomarkers B132.",
        "alphaRelMean": "Main-phase mean relative alpha power (alphaRel = alpha8-12Hz / totalBandPower). Calibration-independent; sum with thetaRel+betaRel+... ≈ 1.0. B122.",
        "thetaRelMean": "Main-phase mean relative theta power. Calibration-independent. B122.",
        "betaRelMean": "Main-phase mean relative beta power. Calibration-independent. Lower = stronger beta suppression regardless of absolute amplitude. B122.",
        "ecdfMax": "Peak ecdfDisplay reached during session [0,1]. inDeep gate requires ≥0.70 sustained 10s (kEnterSustained=20 windows). ecdfMax shows whether the threshold was ever approached. B122.",
        "ecdfP90": "90th-percentile ecdfDisplay across all session samples. Robust peak indicator — unlike ecdfMax, not inflated by single-sample artifact spikes. B122.",
        "gateEvent": "NDJSON record (_type=gateEvent): path=cleared|timeout, tp9Tier, tp10Tier, time. time=-1.0 if gate fired before session start. B122.",
        "enterSustainedAtSession": "Sustained-window requirement active for this session (windows × 0.5s = seconds). Adapts via EnterSustainedShaping: 3 zero-deep sessions → -2 windows (min 4); 3 hit sessions → +1 window (max 20). Default 12 (6s). B126.",
        "alphaThetaMean": "Mean of (frontalTheta / frontalAlpha) ratio in linear band power, averaged over all calibrated windows. Values >1.0 = theta-dominant. Computed per channel then averaged: (af7Theta/af7Alpha + af8Theta/af8Alpha)/2. B126.",
        "alphaThetaCrossoverCount": "Count of 0.5s windows where frontal theta/alpha ratio > 1.0 (theta exceeds alpha in linear band power). Each window ≈ 2 EEG FFT frames. B126.",
        "alphaThetaCrossoverFirstTime": "Seconds from session start to first window where theta > alpha. nil if no crossover occurred. B126.",
        "chiDrift": "Aperiodic slope drift: mean χ over last 120 main-phase samples minus mean χ over warmup-phase samples (chi = IRASA 1/f exponent, AperiodicSlope.swift). Positive = slope steepened (typical in deep absorption); >|0.3| triggers telemetry notice. Nil if <5 chi samples in either window. B129.",
        "readinessScore": "Composite warmup predictor 0–6: warmupFAAMean(<-0.15=2,<0=1,≥0=0) + warmupAperiodicSlopeMean(≥-1.25=2,≥-1.35=1,<-1.35=0) + calibrationIndexMean(<-0.30=2,<-0.10=1,≥-0.10=0). ≥5=primed, 3–4=mixed, ≤2=low-readiness. Nil if all three source fields nil. Empirical basis n=10 (Jun 2026); thresholds provisional. SOURCE=SessionRecorder.swift B135."
    ]

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
                    try data.write(to: writingURL, options: [.atomic, .completeFileProtectionUnlessOpen])
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
        var footerRecord:  NDJSONFooter?   // B120: recover biomarkers when footer is present
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
                // B120: decode full footer so biomarkers (physiologicalScore, HRV scalars,
                // calibrationBeta, betaZScore etc.) survive when save() failed mid-session.
                footerRecord = try? dec.decode(NDJSONFooter.self, from: data)

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

        var rec = SessionRecord(
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
            enterThresholdAtSession: footerRecord?.enterThresholdAtSession ?? enterThresholdFromNDJSON,
            qualityScore:         footerRecord?.qualityScore ?? synthQuality
        )
        // B120: populate biomarkers from footer when available (footer-present NDJSON =
        // endSession() ran but save() failed; all attach*() calls had already fired).
        if let f = footerRecord {
            rec.physiologicalScore       = f.physiologicalScore
            rec.betaZScore               = f.betaZScore
            rec.rmssdScore               = f.rmssdScore
            rec.coherenceScore           = f.coherenceScore
            rec.rmssd                    = f.rmssd
            rec.calibrationRmssd         = f.calibrationRmssd
            rec.dfaAlpha1                = f.dfaAlpha1
            rec.sdnn                     = f.sdnn
            rec.sd1                      = f.sd1
            rec.sd2                      = f.sd2
            rec.calibrationBetaMean      = f.calibrationBetaMean
            rec.calibrationBetaStd       = f.calibrationBetaStd
            rec.calibrationBetaAttached  = f.calibrationBetaAttached
            rec.faaConvention            = f.faaConvention
            rec.rmssdDepthDelta          = f.rmssdDepthDelta
            rec.meditationIndexCorrelation = f.meditationIndexCorrelation
            rec.warmupFAAMean            = f.warmupFAAMean
            rec.mainBetaMean             = f.mainBetaMean
            rec.stallCount               = f.stallCount
            rec.bleReconnectCount        = f.bleReconnectCount
            rec.timeOfDay                = f.timeOfDay
            rec.betaZRaw                 = f.betaZRaw
            rec.signalQualityMeanSpikes  = f.signalQualityMeanSpikes
            rec.signalQualityAlphaPowerRatio = f.signalQualityAlphaPowerRatio
            rec.potatoFlaggedPct            = f.potatoFlaggedPct
            rec.warmupPotatoFlaggedPct      = f.warmupPotatoFlaggedPct
            rec.mainPotatoFlaggedPct        = f.mainPotatoFlaggedPct
            rec.alphaRelMean             = f.alphaRelMean
            rec.thetaRelMean             = f.thetaRelMean
            rec.betaRelMean              = f.betaRelMean
            rec.ecdfMax                  = f.ecdfMax
            rec.ecdfP90                  = f.ecdfP90
            rec.chiDrift                    = f.chiDrift
            rec.warmupAperiodicSlopeMean    = f.warmupAperiodicSlopeMean
            rec.readinessScore              = f.readinessScore
            rec.lfhfMean                    = f.lfhfMean
            // B126 fields — previously missing from crash recovery
            rec.alphaThetaMean              = f.alphaThetaMean
            rec.alphaThetaCrossoverCount    = f.alphaThetaCrossoverCount
            rec.alphaThetaCrossoverFirstTime = f.alphaThetaCrossoverFirstTime
        }
        return rec
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

    /// B126: stash the per-session sustained-window requirement so the footer exports it.
    /// Called from App.swift immediately after startSession(). Uses queue.sync to match
    /// the pattern of attachEnterThreshold (same guard: isRecording must be true).
    func attachEnterSustained(_ windows: Int) {
        queue.sync {
            guard isRecording else { return }
            current?.enterSustainedAtSession = windows
        }
    }

    /// B126: stash alpha-theta summary at session end so the footer exports it.
    func attachAlphaThetaSummary(mean: Float?, crossoverCount: Int, crossoverFirstTime: Double?) {
        queue.sync {
            guard isRecording else { return }
            current?.alphaThetaMean              = mean
            current?.alphaThetaCrossoverCount    = crossoverCount
            current?.alphaThetaCrossoverFirstTime = crossoverFirstTime
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
        // B117 F4+F5: detect default values (DepthScore initializes calibrationBetaMean=0.0, Std=0.30).
        // Real calibration produces non-default values; defaults mean finalizeBaseline never ran
        // in time. Caller (App.swift) MUST call DepthScore.forceFinalize() before reading these.
        let attachedReal = (mean != 0.0) || (std != 0.30)
        // B120: guard on current != nil, not isRecording. scorer.onResult fires on a background
        // thread; startSession() sets isRecording=true via DispatchQueue.main.async. The subsequent
        // queue.sync here runs before main processes that async (queue.sync is immediate; main.async
        // requires a run-loop cycle). isRecording is false → guard would fire → calibrationBeta lost.
        // current is set synchronously inside startSession()'s queue.sync — safe to use as the gate.
        Telemetry.recording.notice("calibrationBeta attach: mean=\(mean, privacy: .public) std=\(std, privacy: .public) isRecording=\(self.isRecording, privacy: .public) attached=\(attachedReal, privacy: .public)")
        queue.sync {
            guard current != nil else { return }
            current?.calibrationBetaMean    = mean
            current?.calibrationBetaStd     = std
            current?.calibrationBetaAttached = attachedReal
        }
    }

    /// B117 F3 — emit a single calibrationSummary NDJSON record at warmup→main transition.
    /// Call AFTER DepthScore.forceFinalize() so values are real, not defaults.
    func attachCalibrationSummary(indexMean: Float,
                                  indexStd: Float,
                                  betaMean: Float,
                                  betaStd: Float,
                                  sampleCount: Int,
                                  durationSec: Double) {
        queue.sync {
            guard isRecording, let rec = current else { return }
            let t = Date().timeIntervalSince(rec.startDate)
            appendLine(NDJSONCalibrationSummary(
                time: t,
                calibrationIndexMean: indexMean,
                calibrationIndexStd: indexStd,
                calibrationBetaMean: betaMean,
                calibrationBetaStd: betaStd,
                calibrationSampleCount: sampleCount,
                calibrationDurationSec: durationSec
            ))
            Telemetry.recording.notice("calibrationSummary emitted: idxMean=\(indexMean, privacy: .public) idxStd=\(indexStd, privacy: .public) betaMean=\(betaMean, privacy: .public) betaStd=\(betaStd, privacy: .public) n=\(sampleCount, privacy: .public)")
        }
    }

    /// B117 C5 — log a coaching intervention with the EEG/HRV state at trigger time.
    /// Required for post-hoc evaluation of which interventions actually shift physiology.
    func recordCoach(trigger: String,
                     diagnosis: String? = nil,
                     intervention: String,
                     speechText: String? = nil,
                     snapshot: CoachStateSnapshot) {
        queue.sync {
            guard isRecording, let rec = current else { return }
            let t = Date().timeIntervalSince(rec.startDate)
            appendLine(NDJSONCoach(
                time: t,
                trigger: trigger,
                diagnosis: diagnosis,
                intervention: intervention,
                speechText: speechText,
                stateAtTrigger: snapshot
            ))
            let ecdfStr = snapshot.ecdfDisplay.map { String(format: "%.3f", $0) } ?? "nil"
            let faaStr  = snapshot.faa.map        { String(format: "%.3f", $0) } ?? "nil"
            Telemetry.recording.notice("coach: trigger=\(trigger, privacy: .public) intervention=\(intervention, privacy: .public) ecdf=\(ecdfStr, privacy: .public) faa=\(faaStr, privacy: .public)")
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
