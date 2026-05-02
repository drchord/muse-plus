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
            Pt(id: "\(s.id)α", t: s.time, v: Double(s.alpha), band: "Alpha"),
            Pt(id: "\(s.id)θ", t: s.time, v: Double(s.theta), band: "Theta"),
            Pt(id: "\(s.id)β", t: s.time, v: Double(s.beta),  band: "Beta"),
            Pt(id: "\(s.id)δ", t: s.time, v: Double(s.delta), band: "Delta"),
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
            .interpolationMethod(.catmullRom)
        }
        .chartForegroundStyleScale([
            "Alpha": Color.blue,
            "Theta": Color.purple,
            "Beta":  Color.red,
            "Delta": Color.teal,
            "Gamma": Color.orange,
        ])
        .chartYScale(domain: -3.0...1.0)
        .chartYAxis {
            AxisMarks(values: [-3, -2, -1, 0, 1]) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .frame(height: 220)
    }
}
