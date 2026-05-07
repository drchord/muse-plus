import Foundation

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
    // Enables offline analysis of calibration quality without re-running the scorer.
    var calibrationIndexMean: Float? = nil
    var calibrationIndexStd:  Float? = nil

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

// MARK: - Recorder

final class SessionRecorder: ObservableObject {
    static let shared = SessionRecorder()

    @Published var isRecording   = false
    @Published var savedSessions: [URL] = []

    private var current:      SessionRecord?
    private var lastDeepState = false

    // MARK: - Lifecycle

    func startSession(calibrationIndexMean: Float? = nil, calibrationIndexStd: Float? = nil) {
        guard !isRecording else { return }
        let now = Date()
        current = SessionRecord(
            id:        ISO8601DateFormatter().string(from: now),
            startDate: now, endDate: nil,
            samples: [], episodes: [], fitEvents: [],
            calibrationIndexMean: calibrationIndexMean,
            calibrationIndexStd:  calibrationIndexStd
        )
        lastDeepState = false
        isRecording   = true
    }

    @discardableResult
    func endSession() -> URL? {
        guard isRecording, var rec = current else { return nil }
        rec.endDate = Date()
        if lastDeepState && !rec.episodes.isEmpty {
            let t = rec.endDate!.timeIntervalSince(rec.startDate)
            rec.episodes[rec.episodes.count - 1].exitTime = t
        }
        isRecording   = false
        current       = nil
        lastDeepState = false
        return save(rec)
    }

    // MARK: - Data ingestion

    func addSample(alpha: Float, theta: Float, beta: Float,
                   delta: Float, gamma: Float, depth: Float, inDeep: Bool,
                   heartRateBPM: Float? = nil, faa: Float? = nil,
                   aperiodicSlopeMean: Float? = nil, iTPFFrontal: Float? = nil,
                   rmssd: Float? = nil, lfhfRatio: Float? = nil) {
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
        rec.samples.append(sample)
        if inDeep && !lastDeepState {
            rec.episodes.append(DeepEpisode(enterTime: t, exitTime: nil))
        } else if !inDeep && lastDeepState && !rec.episodes.isEmpty {
            rec.episodes[rec.episodes.count - 1].exitTime = t
        }
        lastDeepState = inDeep
        current       = rec
    }

    func addFitEvent() {
        guard isRecording, var rec = current else { return }
        let t = Date().timeIntervalSince(rec.startDate)
        rec.fitEvents.append(t)
        current = rec
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
        loadSavedSessions()
    }

    private func save(_ rec: SessionRecord) -> URL? {
        let dir = sessionsDir()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmm"
        let name = "session_\(fmt.string(from: rec.startDate)).json"
        let url  = dir.appendingPathComponent(name)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting     = .prettyPrinted
        guard let data = try? enc.encode(rec) else { return nil }
        try? data.write(to: url)
        loadSavedSessions()
        return url
    }

    private func sessionsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("MuseSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
