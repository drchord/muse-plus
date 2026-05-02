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

    var body: some View {
        Chart(pts) { pt in
            LineMark(
                x: .value("t", pt.t),
                y: .value("log₁₀ µV²", pt.v)
            )
            .foregroundStyle(by: .value("Band", pt.band))
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.catmullRom)
        }
        .chartForegroundStyleScale([
            "Delta": Color(red: 0.20, green: 0.80, blue: 0.20),   // bright green
            "Theta": Color(red: 0.68, green: 0.32, blue: 0.87),   // violet
            "Alpha": Color(red: 0.00, green: 0.48, blue: 1.00),   // iOS blue
            "Beta":  Color(red: 1.00, green: 0.58, blue: 0.00),   // amber
            "Gamma": Color(red: 1.00, green: 0.18, blue: 0.33),   // hot red
        ])
        .chartYScale(domain: -2.5...1.5)
        .chartYAxis {
            AxisMarks(values: [-2, -1, 0, 1]) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .frame(height: 220)
    }
}
