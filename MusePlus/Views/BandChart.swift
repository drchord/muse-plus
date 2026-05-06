import Charts
import SwiftUI

struct BandChart: View {
    let history: [BandSample]

    // MARK: - Lane model

    private struct Lane {
        let band:     String
        let greek:    String
        let lo:       Float
        let hi:       Float
        let index:    Int
        let labelHz:  Int                        // Hz at bottom boundary of this lane
        let peak:     KeyPath<BandSample, Float> // which peak field to read
    }

    // Gamma excluded from chart — 30–50 Hz scalp signal is EMG-dominated on consumer
    // headbands. Delta/theta/alpha/beta cover all clinically meaningful meditation signal.
    private static let lanes: [Lane] = [
        Lane(band: "Delta", greek: "δ", lo: 1,  hi: 4,  index: 0, labelHz: 1,  peak: \.deltaPeak),
        Lane(band: "Theta", greek: "θ", lo: 4,  hi: 8,  index: 1, labelHz: 4,  peak: \.thetaPeak),
        Lane(band: "Alpha", greek: "α", lo: 8,  hi: 13, index: 2, labelHz: 8,  peak: \.alphaPeak),
        Lane(band: "Beta",  greek: "β", lo: 13, hi: 30, index: 3, labelHz: 13, peak: \.betaPeak),
    ]

    // Hz label for the top gridline (top of beta = bottom of excluded gamma)
    private static let topBoundaryHz = 30

    // Mind Monitor color scheme — keyed by band name, used by chart + header rows
    static let colors: [String: Color] = [
        "Delta": Color(red: 1.00, green: 0.22, blue: 0.22),
        "Theta": Color(red: 0.72, green: 0.28, blue: 1.00),
        "Alpha": Color(red: 0.18, green: 0.82, blue: 1.00),
        "Beta":  Color(red: 0.38, green: 0.90, blue: 0.22),
        "Gamma": Color(red: 1.00, green: 0.58, blue: 0.00),  // header only
    ]

    // MARK: - Chart data

    private struct Pt: Identifiable {
        let id: String
        let t:  Double
        let v:  Double   // lane-normalized coordinate, not Hz
        let band: String
    }

    // Map peak Hz into a stacked-lane coordinate:
    //   lane 0 → [0, 1)  (delta)
    //   lane 1 → [1, 2)  (theta)
    //   lane 2 → [2, 3)  (alpha)
    //   lane 3 → [3, 4)  (beta)
    // Returns nil only if hz == 0 (undetected peak — omits the point rather than
    // drawing a misleading flat line at the lane floor).
    private static func laneY(_ hz: Float, lane: Lane) -> Double? {
        guard hz > 0 else { return nil }
        let clamped = min(max(hz, lane.lo), lane.hi)
        return Double((clamped - lane.lo) / (lane.hi - lane.lo)) + Double(lane.index)
    }

    private var pts: [Pt] {
        history.flatMap { s in
            Self.lanes.compactMap { lane -> Pt? in
                guard let v = Self.laneY(s[keyPath: lane.peak], lane: lane) else { return nil }
                return Pt(id: "\(s.id)\(lane.greek)", t: s.time, v: v, band: lane.band)
            }
        }
    }

    private var xDomain: ClosedRange<Double> {
        guard let last = history.last else { return 0...60 }
        return max(0, last.time - 60)...last.time
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Current values header ─────────────────────────────────────
            if let s = history.last {
                VStack(alignment: .leading, spacing: 3) {
                    valueRow("Delta", greek: "δ", range: "1–4",   hz: s.deltaPeak)
                    valueRow("Theta", greek: "θ", range: "4–8",   hz: s.thetaPeak)
                    valueRow("Alpha", greek: "α", range: "8–13",  hz: s.alphaPeak)
                    valueRow("Beta",  greek: "β", range: "13–30", hz: s.betaPeak)
                    valueRow("Gamma", greek: "γ", range: "30–50", hz: s.gammaPeak)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }

            // ── Chart (δ/θ/α/β lanes, equal vertical space per band) ────
            Chart {
                // Alternating lane backgrounds: subtle stripes on lanes 0 (δ) and 2 (α)
                // so each band's lane is visually distinct without needing to read labels.
                if let tFirst = history.first?.time, let tLast = history.last?.time {
                    ForEach([0, 2], id: \.self) { laneIdx in
                        RectangleMark(
                            xStart: .value("t", tFirst),
                            xEnd:   .value("t", tLast),
                            yStart: .value("Band position", Double(laneIdx)),
                            yEnd:   .value("Band position", Double(laneIdx) + 1.0)
                        )
                        .foregroundStyle(Color.white.opacity(0.04))
                    }
                }
                // Band peak lines
                ForEach(pts) { pt in
                    LineMark(
                        x: .value("t",             pt.t),
                        y: .value("Band position", pt.v)
                    )
                    .foregroundStyle(by: .value("Band", pt.band))
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartForegroundStyleScale(
                domain: Self.lanes.map(\.band),
                range:  Self.lanes.map { Self.colors[$0.band] ?? .white }
            )
            .chartXScale(domain: xDomain)
            .chartYScale(domain: -0.05...4.05)
            .chartYAxis {
                // One gridline per lane boundary. Label: "δ 1Hz", "θ 4Hz", etc.
                // At the top boundary (lane 4 = 30 Hz), no band name — just the Hz mark.
                AxisMarks(position: .trailing, values: [0.0, 1.0, 2.0, 3.0, 4.0]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.white.opacity(0.18))
                    if let v = value.as(Double.self) {
                        let idx = Int(v.rounded())
                        if idx < Self.lanes.count {
                            let lane = Self.lanes[idx]
                            AxisValueLabel("\(lane.greek) \(lane.labelHz)Hz")
                                .foregroundStyle(Color.white.opacity(0.45))
                                .font(.system(size: 10))
                        } else {
                            AxisValueLabel("\(Self.topBoundaryHz)Hz")
                                .foregroundStyle(Color.white.opacity(0.25))
                                .font(.system(size: 10))
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { $0.background(Color.clear) }
            .frame(height: 220)
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Header row

    @ViewBuilder
    private func valueRow(_ band: String, greek: String, range: String, hz: Float) -> some View {
        let c = Self.colors[band] ?? .white
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(greek)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(c)
                .frame(width: 22, alignment: .leading)
            Text(band)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(c.opacity(0.65))
                .frame(width: 52, alignment: .leading)
            Text("\(range) Hz")
                .font(.system(size: 12, weight: .regular).monospacedDigit())
                .foregroundStyle(c.opacity(0.38))
                .frame(width: 54, alignment: .leading)
            Spacer()
            Text("\(Int(hz.rounded())) Hz")
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundStyle(c)
        }
    }
}
