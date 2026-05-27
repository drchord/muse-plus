import Charts
import SwiftUI

// MARK: - Point types

private struct DepthPt: Identifiable {
    let id: Int
    let t:  Double   // minutes from session start
    let v:  Double   // ecdfDisplay [0, 1]
}

private struct BandPt: Identifiable {
    let id:   String
    let t:    Double  // minutes
    let v:    Double  // relative power [0, 1]
    let band: String  // "Alpha" | "Theta" | "Beta"
}

private struct HRVPt: Identifiable {
    let id: Int
    let t:  Double   // minutes
    let ms: Double   // RMSSD in ms
}

private struct ChiPt: Identifiable {
    let id: Int
    let t:  Double   // minutes
    let chi: Double  // aperiodic exponent (typically negative)
}

// MARK: - SessionDashboardView

struct SessionDashboardView: View {
    let record: SessionRecord

    // MARK: Data

    private let maxPts = 400

    private func stride<T>(of arr: [T]) -> Int {
        arr.count > maxPts ? arr.count / maxPts : 1
    }

    private var depthPts: [DepthPt] {
        let all = record.samples.enumerated().compactMap { i, s -> DepthPt? in
            guard let v = s.ecdfDisplay else { return nil }
            return DepthPt(id: i, t: s.time / 60.0, v: Double(v))
        }
        let st = stride(of: all)
        return all.enumerated().compactMap { i, p in i % st == 0 ? p : nil }
    }

    private var episodes: [(enter: Double, exit: Double)] {
        record.episodes.map { ep in
            let e = ep.exitTime.map { $0 / 60.0 } ?? record.durationMinutes
            return (ep.enterTime / 60.0, e)
        }
    }

    private var stallMinutes: [Double] {
        (record.eventStream ?? [])
            .filter { $0.kind == "induction-stall" }
            .map { $0.time / 60.0 }
    }

    private var bandPts: [BandPt] {
        var all: [BandPt] = []
        for (i, s) in record.samples.enumerated() {
            if let v = s.alphaRel { all.append(BandPt(id: "a\(i)", t: s.time/60, v: Double(v), band: "Alpha")) }
            if let v = s.thetaRel { all.append(BandPt(id: "t\(i)", t: s.time/60, v: Double(v), band: "Theta")) }
            if let v = s.betaRel  { all.append(BandPt(id: "b\(i)", t: s.time/60, v: Double(v), band: "Beta"))  }
        }
        let st = max(1, all.count / (maxPts * 3))
        return all.enumerated().compactMap { i, p in i % st == 0 ? p : nil }
    }

    private var hrvPts: [HRVPt] {
        let all = record.samples.enumerated().compactMap { i, s -> HRVPt? in
            guard let r = s.rmssd, r > 0 else { return nil }
            return HRVPt(id: i, t: s.time / 60.0, ms: Double(r))
        }
        let st = stride(of: all)
        return all.enumerated().compactMap { i, p in i % st == 0 ? p : nil }
    }

    private var chiPts: [ChiPt] {
        let all = record.samples.enumerated().compactMap { i, s -> ChiPt? in
            guard let c = s.aperiodicSlopeMean else { return nil }
            return ChiPt(id: i, t: s.time / 60.0, chi: Double(c))
        }
        let st = stride(of: all)
        return all.enumerated().compactMap { i, p in i % st == 0 ? p : nil }
    }

    private var threshold: Double { Double(record.enterThresholdAtSession ?? 0.70) }
    private var durMin: Double { record.durationMinutes }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                depthCard
                if !bandPts.isEmpty   { bandCard   }
                if !hrvPts.isEmpty    { hrvCard     }
                if !chiPts.isEmpty    { chiCard     }
            }
            .padding(16)
        }
        .navigationTitle("Session Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Depth Card

    private var depthCard: some View {
        let deepF  = record.deepFraction ?? 0
        let ecdfMax = Double(record.ecdfMax ?? 0)
        let sub: String = {
            if deepF > 0 {
                return "\(Int(deepF * 100))% deep · \(record.episodes.count) episode\(record.episodes.count == 1 ? "" : "s")"
            }
            if record.ecdfMax != nil {
                return "Peak: \(Int(ecdfMax * 100))th pct · no deep entry"
            }
            return "No deep state"
        }()
        let explanation = "Your personal-history depth percentile throughout the session. Orange dashed = entry threshold (\(Int(threshold * 100))th pct). Green zones = confirmed deep state. 🔔 = coaching trigger. Purple = first theta-above-alpha moment."
        let action: String? = {
            if deepF > 0.5                      { return nil }
            if deepF > 0 {
                let longest = record.episodes.compactMap(\.duration).max() ?? 0
                if longest < 300 {
                    return "Deep state confirmed but episodes are short. The pattern is accessible — on the next entry, drop attention from the monitoring of it and let it self-sustain."
                }
                return nil
            }
            if ecdfMax >= threshold             { return "You hit the threshold but couldn't hold it. The gate requires \(fmtSecs(Double(record.enterSustainedAtSession ?? 12) * 0.5)) sustained. Remove the watching — the observing mind is the brake." }
            if ecdfMax >= threshold * 0.85 {
                let gap = Int(((threshold - ecdfMax) * 100).rounded())
                return "\(gap) percentile point\(gap == 1 ? "" : "s") from the gate. Patience, not effort — this gap closes through consistency."
            }
            return "Depth was low today. Check headband fit and try 3 slow full breaths before tapping start to pre-load the parasympathetic response."
        }()
        return card(title: "Depth Over Time", subtitle: sub, explanation: explanation, actionable: action) {
            Chart {
                ForEach(Array(episodes.enumerated()), id: \.offset) { _, ep in
                    RectangleMark(xStart: .value("e", ep.enter), xEnd: .value("x", ep.exit),
                                  yStart: .value("y", 0.0),      yEnd: .value("y", 1.0))
                        .foregroundStyle(Color.green.opacity(0.15))
                }
                ForEach(depthPts) { pt in
                    LineMark(x: .value("min", pt.t), y: .value("depth", pt.v))
                        .foregroundStyle(Color.cyan.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                }
                RuleMark(y: .value("threshold", threshold))
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                    .annotation(position: .trailing, alignment: .leading, spacing: 2) {
                        Text("\(Int((threshold * 100).rounded()))th")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    }
                ForEach(Array(stallMinutes.enumerated()), id: \.offset) { _, t in
                    RuleMark(x: .value("stall", t))
                        .foregroundStyle(Color.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .center, spacing: 1) {
                            Text("🔔").font(.system(size: 7))
                        }
                }
                if let xSec = record.alphaThetaCrossoverFirstTime {
                    RuleMark(x: .value("θ>α", xSec / 60.0))
                        .foregroundStyle(Color.purple.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("θ>α").font(.system(size: 8)).foregroundStyle(.purple)
                        }
                }
            }
            .chartXScale(domain: 0...max(durMin, 1))
            .chartYScale(domain: 0.0...1.0)
            .chartXAxisLabel("min", alignment: .trailing)
            .chartYAxisLabel("pct", alignment: .topLeading)
            .frame(height: 190)
        }
    }

    // MARK: - Band Card

    private var bandCard: some View {
        let n   = record.alphaThetaCrossoverCount ?? 0
        let sub = n > 0 ? "θ>α crossover \(n)×" : "Relative band powers"
        let explanation = "Alpha (cyan) = calm awareness 8–13 Hz. Theta (purple) = deep meditation / absorption 4–8 Hz. Beta (green) = active thinking 13–30 Hz. Relative powers sum to ~1 and are calibration-independent."
        let deepF = record.deepFraction ?? 0
        let action: String? = {
            if n == 0 && deepF == 0 {
                return "No theta-over-alpha crossover. Alpha dominance = alert but not absorbed. Try closing eyes 2 minutes earlier and extend exhales to 7 seconds to tip the balance toward theta."
            }
            if n > 0 && deepF == 0 {
                let kSec = fmtSecs(Double(record.enterSustainedAtSession ?? 12) * 0.5)
                return "Theta crossed alpha \(n) time\(n == 1 ? "" : "s") but the gate didn't confirm (requires \(Int(threshold * 100))th pct sustained \(kSec)). The signal is there — the hold duration isn't yet."
            }
            return nil
        }()
        return card(title: "Alpha · Theta · Beta", subtitle: sub, explanation: explanation, actionable: action) {
            Chart {
                ForEach(bandPts) { pt in
                    LineMark(x: .value("min", pt.t), y: .value("rel", pt.v))
                        .foregroundStyle(by: .value("Band", pt.band))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                }
                if let xSec = record.alphaThetaCrossoverFirstTime {
                    RuleMark(x: .value("θ>α", xSec / 60.0))
                        .foregroundStyle(Color.purple.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("θ>α").font(.system(size: 8)).foregroundStyle(.purple)
                        }
                }
            }
            .chartForegroundStyleScale(
                domain: ["Alpha", "Theta", "Beta"],
                range:  [Color.cyan, Color.purple, Color.green]
            )
            .chartXScale(domain: 0...max(durMin, 1))
            .chartYScale(domain: 0.0...1.0)
            .chartXAxisLabel("min", alignment: .trailing)
            .chartYAxisLabel("rel", alignment: .topLeading)
            .frame(height: 160)
        }
    }

    // MARK: - HRV Card

    private var hrvCard: some View {
        let vals  = hrvPts.map(\.ms)
        let mean  = vals.isEmpty ? 0.0 : vals.reduce(0, +) / Double(vals.count)
        let zone  = mean < 40 ? "low" : mean < 65 ? "moderate" : "good"
        let sub   = "Mean RMSSD \(Int(mean.rounded()))ms · \(zone)"
        let explanation = "RMSSD = beat-to-beat heart rate variability, the most direct indicator of parasympathetic (rest-and-recover) activation during meditation. Red <40ms (low). Orange 40–65ms (moderate). Green 65ms+ (good). Higher is better."
        let action: String? = {
            guard !vals.isEmpty else { return nil }
            if mean < 40  { return "HRV was low — residual sympathetic activation. Try 4-7-8 breathing (in 4s, hold 7s, out 8s) for 3 cycles before the next session to pre-load parasympathetic tone." }
            if mean < 65  { return "HRV moderate. Longer exhales (5s in / 8s out) shift autonomic balance further toward rest — should lift RMSSD and depth together." }
            return nil
        }()
        return card(title: "Heart Rate Variability", subtitle: sub, explanation: explanation, actionable: action) {
            Chart {
                RectangleMark(xStart: .value("t", 0.0), xEnd: .value("t", max(durMin, 1)),
                              yStart: .value("y",  0.0), yEnd: .value("y", 40.0))
                    .foregroundStyle(Color.red.opacity(0.07))
                RectangleMark(xStart: .value("t", 0.0), xEnd: .value("t", max(durMin, 1)),
                              yStart: .value("y", 40.0), yEnd: .value("y", 65.0))
                    .foregroundStyle(Color.orange.opacity(0.07))
                RectangleMark(xStart: .value("t", 0.0), xEnd: .value("t", max(durMin, 1)),
                              yStart: .value("y", 65.0), yEnd: .value("y", max(150.0, vals.max() ?? 100)))
                    .foregroundStyle(Color.green.opacity(0.07))
                ForEach(hrvPts) { pt in
                    LineMark(x: .value("min", pt.t), y: .value("ms", pt.ms))
                        .foregroundStyle(Color.pink.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                }
                RuleMark(y: .value("40ms", 40.0))
                    .foregroundStyle(Color.orange.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(y: .value("65ms", 65.0))
                    .foregroundStyle(Color.green.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: 0...max(durMin, 1))
            .chartXAxisLabel("min", alignment: .trailing)
            .chartYAxisLabel("ms", alignment: .topLeading)
            .frame(height: 160)
        }
    }

    // MARK: - Chi Card

    private var chiCard: some View {
        let sub: String = {
            if let drift = record.chiDrift {
                return "χ drift \(drift > 0 ? "+" : "")\(String(format: "%.2f", drift)) (more neg = deeper)"
            }
            let vals = chiPts.map(\.chi)
            if !vals.isEmpty {
                let mean = vals.reduce(0, +) / Double(vals.count)
                return "Mean χ \(String(format: "%.2f", mean))"
            }
            return "1/f slope"
        }()
        let explanation: String = {
            var parts = ["The aperiodic (1/f) slope χ measures how steeply brain power falls off with frequency. More negative = steeper = deeper absorption (large-scale synchronized slow oscillations). The green dashed line at χ = –1.5 marks the absorption zone."]
            if let drift = record.chiDrift {
                let dir = drift > 0 ? "steepened toward absorption (+\(String(format: "%.2f", drift)))" : "flattened away from absorption (\(String(format: "%.2f", drift)))"
                parts.append("Chi \(dir) over the session.")
            }
            return parts.joined(separator: " ")
        }()
        let action: String? = {
            if let drift = record.chiDrift {
                if drift > 0.3  { return nil }
                if drift < -0.3 { return "Chi flattened during the session — absorption decreased. This can indicate fatigue or wandering attention in the second half. Try capping sessions at 40 minutes until the slope stabilizes." }
            }
            let vals = chiPts.map(\.chi)
            if !vals.isEmpty {
                let mean = vals.reduce(0, +) / Double(vals.count)
                if mean > -1.0 { return "Chi stayed shallow (mean χ = \(String(format: "%.2f", mean))). Building theta synchronization (alpha-theta practice) typically pulls chi more negative. Focus on holding theta above alpha for longer stretches." }
            }
            return nil
        }()
        return card(title: "Aperiodic Slope (1/f)", subtitle: sub, explanation: explanation, actionable: action) {
            Chart {
                RuleMark(y: .value("absorption", -1.5))
                    .foregroundStyle(Color.green.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .trailing, alignment: .leading, spacing: 3) {
                        Text("absorption")
                            .font(.system(size: 8)).foregroundStyle(.green.opacity(0.7))
                    }
                ForEach(chiPts) { pt in
                    LineMark(x: .value("min", pt.t), y: .value("χ", pt.chi))
                        .foregroundStyle(Color.yellow.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXScale(domain: 0...max(durMin, 1))
            .chartXAxisLabel("min", alignment: .trailing)
            .chartYAxisLabel("χ", alignment: .topLeading)
            .frame(height: 150)
        }
    }

    // MARK: - Card layout

    @ViewBuilder
    private func card<C: View>(
        title: String,
        subtitle: String,
        explanation: String,
        actionable: String?,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = actionable {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(action)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Helpers

    private func fmtSecs(_ s: Double) -> String {
        s == floor(s) ? "\(Int(s))s" : String(format: "%.1fs", s)
    }
}
