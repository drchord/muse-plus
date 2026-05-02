import Charts
import SwiftUI

struct BandChart: View {
    let history: [BandSample]

    private struct Pt: Identifiable {
        let id: String
        let t: Double
        let v: Double
        let band: String
    }

    private var pts: [Pt] {
        history.flatMap { s in [
            Pt(id: "\(s.id)δ", t: s.time, v: Double(s.delta), band: "Delta"),
            Pt(id: "\(s.id)θ", t: s.time, v: Double(s.theta), band: "Theta"),
            Pt(id: "\(s.id)α", t: s.time, v: Double(s.alpha), band: "Alpha"),
            Pt(id: "\(s.id)β", t: s.time, v: Double(s.beta),  band: "Beta"),
            Pt(id: "\(s.id)γ", t: s.time, v: Double(s.gamma), band: "Gamma"),
        ]}
    }

    private var xDomain: ClosedRange<Double> {
        guard let last = history.last else { return 0...60 }
        return max(0, last.time - 60)...last.time
    }

    // Mind Monitor color scheme
    static let colors: [String: Color] = [
        "Delta": Color(red: 1.00, green: 0.22, blue: 0.22),  // red
        "Theta": Color(red: 0.72, green: 0.28, blue: 1.00),  // violet-purple
        "Alpha": Color(red: 0.18, green: 0.82, blue: 1.00),  // cyan
        "Beta":  Color(red: 0.38, green: 0.90, blue: 0.22),  // lime green
        "Gamma": Color(red: 1.00, green: 0.58, blue: 0.00),  // orange
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Current values header ─────────────────────────────────
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

            // ── Chart ─────────────────────────────────────────────────
            Chart(pts) { pt in
                LineMark(
                    x: .value("t", pt.t),
                    y: .value("log₁₀ µV²", pt.v)
                )
                .foregroundStyle(by: .value("Band", pt.band))
                .lineStyle(StrokeStyle(lineWidth: 3))
                .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(
                domain: ["Delta", "Theta", "Alpha", "Beta", "Gamma"],
                range: [
                    Color(red: 1.00, green: 0.22, blue: 0.22),
                    Color(red: 0.72, green: 0.28, blue: 1.00),
                    Color(red: 0.18, green: 0.82, blue: 1.00),
                    Color(red: 0.38, green: 0.90, blue: 0.22),
                    Color(red: 1.00, green: 0.58, blue: 0.00),
                ]
            )
            .chartXScale(domain: xDomain)
            .chartYScale(domain: -2.5...1.5)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [-2, -1, 0, 1]) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel()
                        .foregroundStyle(Color.white.opacity(0.35))
                        .font(.system(size: 10))
                }
            }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { $0.background(Color.clear) }
            .frame(height: 250)
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

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
