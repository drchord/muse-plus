import SwiftUI
import Charts

// Lightweight summary extracted from SessionRecord JSON — avoids loading full sample arrays.
private struct TrendSession: Identifiable {
    let id:            String
    let date:          Date
    let deepFraction:  Double?
    let qualityScore:  Int?
    let durationMin:   Double?
    // B107
    let physiologicalScore:        Int?
    let meditationIndexCorrelation: Float?
    let betaSuppression:           Float?   // calibrationBetaMean - mainBetaMean (positive = good)
    let timeOfDay:                 String?
    let enterThreshold:            Float?
    let rmssd:                     Double?
    let dfaAlpha1:                 Double?
}

// Minimal Codable subset for fast JSON parsing (avoids decoding thousands of samples).
private struct TrendRecord: Codable {
    let id:           String
    let startDate:    Date
    var deepFraction: Double? = nil
    var qualityScore: Int?    = nil
    var durationSec:  Double? = nil
    // B107 additions — all optional for back-compat with pre-B107 files
    var physiologicalScore:        Int?    = nil
    var meditationIndexCorrelation: Float? = nil
    var mainBetaMean:              Float?  = nil
    var calibrationBetaMean:       Float?  = nil
    var timeOfDay:                 String? = nil
    var enterThresholdAtSession:   Float?  = nil
    var rmssd:                     Double? = nil
    var dfaAlpha1:                 Double? = nil
    var stallCount:                Int?    = nil
}

struct TrendsView: View {
    @State private var sessions:       [TrendSession] = []
    @State private var isLoading:      Bool           = true
    @State private var timeOfDayFilter: String?      = nil  // nil = show all

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading sessions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "waveform.path.ecg",
                    description: Text("Complete a session to see trends.")
                )
            } else {
                List {
                    Section {
                        Picker("Time of Day", selection: $timeOfDayFilter) {
                            Text("All").tag(String?.none)
                            Text("Morning").tag(String?.some("morning"))
                            Text("Afternoon").tag(String?.some("afternoon"))
                            Text("Evening").tag(String?.some("evening"))
                            Text("Night").tag(String?.some("night"))
                        }
                        .pickerStyle(.segmented)
                    }

                    deepFractionSection
                    if filteredSessions.contains(where: { $0.qualityScore != nil }) {
                        qualityScoreSection
                    }
                    durationSection
                    if filteredSessions.contains(where: { $0.physiologicalScore != nil }) {
                        physiologicalScoreSection
                    }
                    if filteredSessions.contains(where: { $0.enterThreshold != nil }) {
                        thresholdSection
                    }
                    if filteredSessions.contains(where: { $0.rmssd != nil }) {
                        rmssdSection
                    }
                    if filteredSessions.contains(where: { $0.dfaAlpha1 != nil }) {
                        dfaSection
                    }
                    statsSection
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Session Trends")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSessions() }
    }

    // MARK: - Filtering

    private var filteredSessions: [TrendSession] {
        guard let f = timeOfDayFilter else { return sessions }
        return sessions.filter { $0.timeOfDay == f }
    }

    // MARK: - Chart sections

    private var deepFractionSection: some View {
        Section {
            Chart(filteredSessions) { s in
                if let d = s.deepFraction {
                    AreaMark(x: .value("Date", s.date),
                             y: .value("Deep %", d * 100))
                        .foregroundStyle(.green.opacity(0.15))
                    LineMark(x: .value("Date", s.date),
                             y: .value("Deep %", d * 100))
                        .foregroundStyle(.green)
                    PointMark(x: .value("Date", s.date),
                              y: .value("Deep %", d * 100))
                        .foregroundStyle(.green)
                        .symbolSize(30)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) }
            .frame(height: 180)

            if let arrow = trendArrow(values: filteredSessions.compactMap(\.deepFraction)) {
                Label(arrow.label, systemImage: arrow.icon)
                    .font(.caption)
                    .foregroundStyle(arrow.color)
            }
        } header: {
            Text("Deep Fraction (%)")
        }
    }

    private var qualityScoreSection: some View {
        Section("Quality Score") {
            Chart(filteredSessions.filter { $0.qualityScore != nil }) { s in
                LineMark(x: .value("Date", s.date),
                         y: .value("Score", Double(s.qualityScore!)))
                    .foregroundStyle(.blue)
                PointMark(x: .value("Date", s.date),
                          y: .value("Score", Double(s.qualityScore!)))
                    .foregroundStyle(.blue)
                    .symbolSize(30)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 160)
        }
    }

    private var durationSection: some View {
        Section("Session Duration (min)") {
            Chart(filteredSessions.filter { $0.durationMin != nil }) { s in
                BarMark(x: .value("Date", s.date),
                        y: .value("Min", s.durationMin!))
                    .foregroundStyle(.indigo.opacity(0.65))
                    .cornerRadius(3)
            }
            .frame(height: 120)
        }
    }

    private var statsSection: some View {
        Section("Summary") {
            let deepVals = filteredSessions.compactMap(\.deepFraction)
            if !deepVals.isEmpty {
                LabeledContent("Sessions loaded", value: "\(filteredSessions.count)")
                LabeledContent("Avg deep fraction",
                               value: String(format: "%.0f%%",
                                             deepVals.reduce(0, +) / Double(deepVals.count) * 100))
                LabeledContent("Best session",
                               value: String(format: "%.0f%%", (deepVals.max() ?? 0) * 100))
            }
        }
    }

    private var physiologicalScoreSection: some View {
        Section("Physiological Score") {
            Chart(filteredSessions.filter { $0.physiologicalScore != nil }, id: \.id) { s in
                LineMark(
                    x: .value("Date", s.date),
                    y: .value("Score", s.physiologicalScore!)
                )
                .foregroundStyle(.purple)
                PointMark(
                    x: .value("Date", s.date),
                    y: .value("Score", s.physiologicalScore!)
                )
                .foregroundStyle(.purple)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 150)
        }
    }

    private var thresholdSection: some View {
        Section("Entry Threshold Progression") {
            Chart(filteredSessions.enumerated().compactMap { (i, s) -> (Int, Float)? in
                guard let t = s.enterThreshold else { return nil }
                return (i + 1, t)
            }, id: \.0) { pair in
                LineMark(
                    x: .value("Session", pair.0),
                    y: .value("Threshold (ECDF)", pair.1)
                )
                .foregroundStyle(.orange)
            }
            .chartYScale(domain: 0...1)
            .frame(height: 150)
        }
    }

    private var rmssdSection: some View {
        Section("RMSSD Trend (ms)") {
            Chart(filteredSessions.filter { $0.rmssd != nil }, id: \.id) { s in
                LineMark(
                    x: .value("Date", s.date),
                    y: .value("RMSSD", s.rmssd!)
                )
                .foregroundStyle(.green)
            }
            .frame(height: 150)
        }
    }

    private var dfaSection: some View {
        Section("DFA α1 (Short-Range HRV Scaling)") {
            Chart {
                ForEach(filteredSessions.filter { $0.dfaAlpha1 != nil }, id: \.id) { s in
                    PointMark(
                        x: .value("Date", s.date),
                        y: .value("α1", s.dfaAlpha1!)
                    )
                    .foregroundStyle(.teal)
                }
                RuleMark(y: .value("Healthy", 1.0))
                    .foregroundStyle(.gray.opacity(0.5))
                    .lineStyle(StrokeStyle(dash: [4]))
                    .annotation(position: .trailing) {
                        Text("1.0").font(.caption2).foregroundStyle(.gray)
                    }
            }
            .chartYScale(domain: 0...2)
            .frame(height: 150)
            if filteredSessions.filter({ $0.dfaAlpha1 != nil }).count < 5 {
                Text("DFA α1 needs ≥200 RR intervals per session (~17+ min at 60 BPM)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data loading

    private func loadSessions() async {
        let docs = SessionRecorder.sessionsDirURL()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.nameKey], options: .skipsHiddenFiles
        ) else {
            await MainActor.run { isLoading = false }
            return
        }

        let urls = contents
            .filter { $0.lastPathComponent.hasPrefix("session_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(30)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [TrendSession] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let rec  = try? decoder.decode(TrendRecord.self, from: data)
            else { continue }
            loaded.append(TrendSession(
                id:           rec.id,
                date:         rec.startDate,
                deepFraction: rec.deepFraction,
                qualityScore: rec.qualityScore,
                durationMin:  rec.durationSec.map { $0 / 60 },
                physiologicalScore: rec.physiologicalScore,
                meditationIndexCorrelation: rec.meditationIndexCorrelation,
                betaSuppression: {
                    guard let cal = rec.calibrationBetaMean, let sess = rec.mainBetaMean else { return nil }
                    return cal - sess
                }(),
                timeOfDay:      rec.timeOfDay,
                enterThreshold: rec.enterThresholdAtSession,
                rmssd:          rec.rmssd,
                dfaAlpha1:      rec.dfaAlpha1
            ))
        }

        await MainActor.run {
            self.sessions  = loaded.reversed()   // chronological
            self.isLoading = false
        }
    }

    // MARK: - Trend arrow

    private struct TrendArrow {
        let label: String; let icon: String; let color: Color
    }

    private func trendArrow(values: [Double]) -> TrendArrow? {
        guard values.count >= 7 else { return nil }
        let recent    = values.suffix(7).reduce(0, +) / 7.0
        let priorSlice = values.dropLast(7).suffix(7)
        guard !priorSlice.isEmpty else { return nil }
        let prior  = priorSlice.reduce(0, +) / Double(priorSlice.count)
        let delta  = (recent - prior) * 100          // percentage points
        if delta >  2.0 { return TrendArrow(label: "↑ \(String(format: "%.0f", delta))pp vs prior 7 sessions",  icon: "arrow.up.right",   color: .green) }
        if delta < -2.0 { return TrendArrow(label: "↓ \(String(format: "%.0f", -delta))pp vs prior 7 sessions", icon: "arrow.down.right", color: .orange) }
        return TrendArrow(label: "Steady vs prior 7 sessions", icon: "arrow.right", color: .secondary)
    }
}
