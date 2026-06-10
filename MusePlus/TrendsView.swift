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
    let calibrationIndexMean:      Float?
    // B135
    let alphaThetaMean:            Float?
    let warmupFAAMean:             Float?
    let warmupAperiodicSlopeMean:  Float?
    let calibrationRmssd:          Double?
    let ecdfP90:                   Float?
    let readinessScore:            Int?
}

// Used by thresholdSection Chart — anonymous tuples don't support key-path id in Swift.
private struct ThresholdPoint: Identifiable {
    let id: Int
    let threshold: Float
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
    var calibrationIndexMean:      Float?  = nil   // B108
    var timeOfDay:                 String? = nil
    var enterThresholdAtSession:   Float?  = nil
    var rmssd:                     Double? = nil
    var dfaAlpha1:                 Double? = nil
    var stallCount:                Int?    = nil
    // B135
    var alphaThetaMean:            Float?  = nil
    var warmupFAAMean:             Float?  = nil
    var warmupAperiodicSlopeMean:  Float?  = nil
    var calibrationRmssd:          Double? = nil
    var ecdfP90:                   Float?  = nil
    var readinessScore:            Int?    = nil
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
                    if filteredSessions.contains(where: { $0.alphaThetaMean != nil }) {
                        alphaThetaSection
                    }
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
                    if filteredSessions.contains(where: { $0.calibrationRmssd != nil }) {
                        calibrationRmssdSection
                    }
                    if filteredSessions.contains(where: { $0.dfaAlpha1 != nil }) {
                        dfaSection
                    }
                    if filteredSessions.contains(where: { $0.meditationIndexCorrelation != nil }) {
                        miCorrelationSection
                    }
                    if filteredSessions.contains(where: { $0.calibrationIndexMean != nil }) {
                        calibrationIndexSection
                    }
                    if filteredSessions.contains(where: { $0.betaSuppression != nil }) {
                        betaSuppressionSection
                    }
                    if filteredSessions.contains(where: { $0.warmupFAAMean != nil }) {
                        warmupFAASection
                    }
                    if filteredSessions.contains(where: { $0.warmupAperiodicSlopeMean != nil }) {
                        warmupSlopeSection
                    }
                    if filteredSessions.contains(where: { $0.readinessScore != nil }) {
                        readinessScoreSection
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
            let points = filteredSessions.enumerated().compactMap { (i, s) -> ThresholdPoint? in
                guard let t = s.enterThreshold else { return nil }
                return ThresholdPoint(id: i + 1, threshold: t)
            }
            Chart(points) { pt in
                LineMark(
                    x: .value("Session", pt.id),
                    y: .value("Threshold (ECDF)", pt.threshold)
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

    private var miCorrelationSection: some View {
        Section("MI/Depth Correlation (r)") {
            Chart(filteredSessions.filter { $0.meditationIndexCorrelation != nil }, id: \.id) { s in
                LineMark(x: .value("Date", s.date), y: .value("r", Double(s.meditationIndexCorrelation!)))
                    .foregroundStyle(.mint)
                PointMark(x: .value("Date", s.date), y: .value("r", Double(s.meditationIndexCorrelation!)))
                    .foregroundStyle(.mint)
                    .symbolSize(30)
            }
            .chartYScale(domain: 0...1)
            .chartYAxis { AxisMarks(values: [0.0, 0.4, 0.7, 1.0]) }
            .frame(height: 150)
            Text("r < 0.4 suggests EEG/depth signal mismatch — possible calibration drift.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var calibrationIndexSection: some View {
        Section("Calibration Baseline (ECDF Index)") {
            Chart(filteredSessions.filter { $0.calibrationIndexMean != nil }, id: \.id) { s in
                LineMark(x: .value("Date", s.date), y: .value("Index", Double(s.calibrationIndexMean!)))
                    .foregroundStyle(.orange)
                PointMark(x: .value("Date", s.date), y: .value("Index", Double(s.calibrationIndexMean!)))
                    .foregroundStyle(.orange)
                    .symbolSize(30)
                RuleMark(y: .value("Threshold", -0.20))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(dash: [4]))
            }
            .frame(height: 150)
            Text("More negative = stronger theta/alpha baseline. Sessions landing above −0.20 have produced zero deep state in 3/3 cases (n=8 total, r²=0.84 — signal, not hard gate).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var betaSuppressionSection: some View {
        Section("Beta Suppression (cal − session)") {
            Chart(filteredSessions.filter { $0.betaSuppression != nil }, id: \.id) { s in
                BarMark(x: .value("Date", s.date), y: .value("Δβ", Double(s.betaSuppression!)))
                    .foregroundStyle(s.betaSuppression! >= 0 ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                    .cornerRadius(3)
            }
            .frame(height: 150)
            Text("Positive = beta decreased from calibration to session (expected during deep state). Zero bars mean betaZScore contributed 0 pts to physiologicalScore — check Console for B108 calBeta log.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - B135 chart sections

    private var alphaThetaSection: some View {
        Section("Alpha/Theta Ratio (Depth Signal)") {
            Chart(filteredSessions.filter { $0.alphaThetaMean != nil }, id: \.id) { s in
                LineMark(x: .value("Date", s.date), y: .value("α/θ", Double(s.alphaThetaMean!)))
                    .foregroundStyle(.indigo)
                PointMark(x: .value("Date", s.date), y: .value("α/θ", Double(s.alphaThetaMean!)))
                    .foregroundStyle(s.deepFraction ?? 0 > 0 ? Color.green : Color.indigo)
                    .symbolSize(s.deepFraction ?? 0 > 0 ? 60 : 30)
            }
            .chartYScale(domain: 0...15)
            .chartYAxis { AxisMarks(values: [0, 5, 10, 15]) }
            .frame(height: 160)
            Text("Primary depth gating signal. Green points = sessions with deep episodes. Jun 9 BREAKTHROUGH = 10.65 (+8σ); most sessions sit 2–5. Values >7 correlate with deep entry (n=10, empirical).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var calibrationRmssdSection: some View {
        Section("Calibration RMSSD (Session-Start HRV)") {
            Chart(filteredSessions.filter { $0.calibrationRmssd != nil }, id: \.id) { s in
                LineMark(x: .value("Date", s.date), y: .value("ms", s.calibrationRmssd!))
                    .foregroundStyle(.pink)
                PointMark(x: .value("Date", s.date), y: .value("ms", s.calibrationRmssd!))
                    .foregroundStyle(s.deepFraction ?? 0 > 0 ? Color.green : Color.pink)
                    .symbolSize(s.deepFraction ?? 0 > 0 ? 60 : 30)
                RuleMark(y: .value("≥85ms", 85.0))
                    .foregroundStyle(Color.green.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .trailing, alignment: .leading, spacing: 2) {
                        Text("85").font(.caption2).foregroundStyle(.green.opacity(0.7))
                    }
            }
            .frame(height: 150)
            Text("HRV measured during the calibration window (session start). Green = deep entry occurred. ≥85ms green zone is a positive leading indicator. The session-mean RMSSD (trending separately) is NOT a reliable predictor — it can be high even on zero-depth days (Jun 10 = 77ms, no depth).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var warmupFAASection: some View {
        Section("Warmup FAA (Frontal Asymmetry)") {
            Chart {
                ForEach(filteredSessions.filter { $0.warmupFAAMean != nil }, id: \.id) { s in
                    BarMark(x: .value("Date", s.date), y: .value("FAA", Double(s.warmupFAAMean!)))
                        .foregroundStyle(s.warmupFAAMean! < -0.15 ? Color.green.opacity(0.75)
                                       : s.warmupFAAMean! < 0     ? Color.yellow.opacity(0.75)
                                                                   : Color.orange.opacity(0.75))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("zero", 0.0))
                    .foregroundStyle(Color.gray.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                RuleMark(y: .value("-0.15", -0.15))
                    .foregroundStyle(Color.green.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .trailing, alignment: .leading, spacing: 2) {
                        Text("−0.15").font(.caption2).foregroundStyle(.green.opacity(0.7))
                    }
            }
            .frame(height: 150)
            Text("af8α − af7α during warmup phase. For Sugato: NEGATIVE (right-frontal dominant) predicts depth — green bars. Positive FAA on zero-depth sessions: n=6/6 confirmed pattern. Note: r(FAA, deepFraction) = −0.48, p≈0.10 (trend, not significant at n=10).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var warmupSlopeSection: some View {
        Section("Pre-session 1/f Slope (Warmup χ)") {
            Chart {
                ForEach(filteredSessions.filter { $0.warmupAperiodicSlopeMean != nil }, id: \.id) { s in
                    PointMark(x: .value("Date", s.date),
                              y: .value("χ", Double(s.warmupAperiodicSlopeMean!)))
                        .foregroundStyle(s.deepFraction ?? 0 > 0 ? Color.green : Color.yellow)
                        .symbolSize(s.deepFraction ?? 0 > 0 ? 60 : 30)
                    LineMark(x: .value("Date", s.date),
                             y: .value("χ", Double(s.warmupAperiodicSlopeMean!)))
                        .foregroundStyle(Color.yellow.opacity(0.6))
                }
                RuleMark(y: .value("-1.25", -1.25))
                    .foregroundStyle(Color.green.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .trailing, alignment: .leading, spacing: 2) {
                        Text("−1.25").font(.caption2).foregroundStyle(.green.opacity(0.7))
                    }
                RuleMark(y: .value("-1.35", -1.35))
                    .foregroundStyle(Color.orange.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartYScale(domain: -2.0 ... -0.5)
            .frame(height: 150)
            Text("Mean 1/f aperiodic exponent during warmup (first 5 min). Green = deep entry occurred. Less negative (closer to zero, above −1.25 green line) = lower initial arousal = better depth conditions. Jun 9 = −1.22 (deep), Jun 10 = −1.31 (no depth). Added B132.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var readinessScoreSection: some View {
        Section("Readiness Score (Composite Predictor)") {
            Chart(filteredSessions.filter { $0.readinessScore != nil }, id: \.id) { s in
                BarMark(x: .value("Date", s.date), y: .value("Score", Double(s.readinessScore!)))
                    .foregroundStyle(s.readinessScore! >= 5 ? Color.green.opacity(0.75)
                                   : s.readinessScore! >= 3 ? Color.yellow.opacity(0.75)
                                                            : Color.orange.opacity(0.75))
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...6)
            .chartYAxis { AxisMarks(values: [0, 2, 4, 6]) }
            .frame(height: 130)
            Text("0–6 composite: warmupFAA (0-2) + warmupSlope (0-2) + calibIM (0-2). ≥5 = primed (green), 3–4 = mixed (yellow), ≤2 = low (orange). Empirical basis n=10 sessions Jun 2026. Added B135.")
                .font(.caption).foregroundStyle(.secondary)
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
                rmssd:               rec.rmssd,
                dfaAlpha1:           rec.dfaAlpha1,
                calibrationIndexMean: rec.calibrationIndexMean,
                alphaThetaMean:           rec.alphaThetaMean,
                warmupFAAMean:            rec.warmupFAAMean,
                warmupAperiodicSlopeMean: rec.warmupAperiodicSlopeMean,
                calibrationRmssd:         rec.calibrationRmssd,
                ecdfP90:                  rec.ecdfP90,
                readinessScore:           rec.readinessScore
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
