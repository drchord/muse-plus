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

            current = SessionRecord(
                id:        id,
                startDate: now, endDate: nil,
                samples: [], episodes: [], fitEvents: [],
                calibrationIndexMean: calibrationIndexMean,
                calibrationIndexStd:  calibrationIndexStd,
                marks: [],
                buildTag: "B80"
            )
            lastDeepState = false
            sampleCount   = 0

            // Open NDJSON file handle
            openNDJSONHandle(id: id, now: now,
                             calibrationIndexMean: calibrationIndexMean,
                             calibrationIndexStd:  calibrationIndexStd)

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

    /// Synchronous save — file is on disk before this returns.
    /// Order: stop accepting new samples → close any open episode → feed personal ECDF
    /// → write NDJSON footer → close handle → synthesise .json → refresh saved list.
    @discardableResult
    func endSession(reason: String = "normal") -> URL? {
        queue.sync {
            guard isRecording, var rec = current else { return nil }
            // Stop accepting new samples FIRST.
            DispatchQueue.main.async { self.isRecording = false }

            rec.endDate = Date()
            if lastDeepState && !rec.episodes.isEmpty {
                let t = rec.endDate!.timeIntervalSince(rec.startDate)
                rec.episodes[rec.episodes.count - 1].exitTime = t
            }

            // Write NDJSON footer
            appendFooter(rec: rec, reason: reason)
            closeNDJSONHandle()

            // A3: stop flush timer
            DispatchQueue.main.async {
                self.flushTimer?.invalidate()
                self.flushTimer = nil
            }

            // A4: tear down app-state observers
            tearDownAppStateObservers()

            // Feed personal ECDF
            let allZs = rec.samples.compactMap { s -> Float? in
                guard let z = s.depthZ, z.isFinite else { return nil }
                return z
            }
            if !allZs.isEmpty {
                PersonalZDistribution.shared.ingestSession(zSamples: allZs)
            }

            // Log gap stats
            let times = rec.samples.map(\.time)
            if times.count > 1 {
                let gaps   = zip(times, times.dropFirst()).map { $1 - $0 }
                let mean   = gaps.reduce(0.0, +) / Double(gaps.count)
                let sorted = gaps.sorted()
                let p95    = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
                let maxGap = sorted.last ?? 0
                Telemetry.recording.notice("session ended: samples=\(times.count, privacy: .public) duration=\(String(format: "%.1f", times.last ?? 0), privacy: .public)s gap_mean=\(String(format: "%.3f", mean), privacy: .public)s gap_p95=\(String(format: "%.3f", p95), privacy: .public)s gap_max=\(String(format: "%.3f", maxGap), privacy: .public)s")
            } else {
                Telemetry.recording.notice("session ended: samples=\(times.count, privacy: .public) (too few to compute gaps)")
            }

            current       = nil
            lastDeepState = false
            sampleCount   = 0

            // Synthesise canonical .json from in-memory record (no need to re-parse NDJSON
            // since record is complete in memory at normal end).
            let url = save(rec)

            return url
        }
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
                betaScoreSDK: betaScoreSDK, phase: phase, frontalGood: frontalGood
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

    func addFitEvent() {
        queue.sync {
            guard isRecording, var rec = current else { return }
            let t = Date().timeIntervalSince(rec.startDate)
            rec.fitEvents.append(t)
            current = rec

            let nd = NDJSONFit(_type: "fit", time: t)
            appendLine(nd)
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
            buildTag: "B80"
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

    private func appendFooter(rec: SessionRecord, reason: String) {
        let footer = NDJSONFooter(
            _type: "footer",
            endDate: iso8601.string(from: rec.endDate ?? Date()),
            episodeCount: rec.episodes.count,
            sampleCount:  rec.samples.count,
            endReason:    reason
        )
        appendLine(footer)
        ndjsonHandle?.synchronizeFile()
        Telemetry.recording.notice("NDJSON footer written: samples=\(rec.samples.count, privacy: .public) reason=\(reason, privacy: .public)")
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
            // Atomic write: writes to a temp file then renames into place. Crash-safe —
            // either the old file remains intact or the new file is fully written.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            loadSavedSessions()
            Telemetry.recording.notice("saved \(data.count, privacy: .public) B to \(name, privacy: .public)")
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
            eventStream: nil
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
