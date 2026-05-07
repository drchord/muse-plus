import Foundation

// Tap-to-mark subjective ground truth. The user is the only label source for "depth."
// Standard ESM (experience-sampling method) practice in psychophysiology.
//
// Use: during a session, user taps a button to flag the current moment as
//   - .deepest:    "right now feels like the deepest I've been"
//   - .shallowest: "right now feels like the shallowest"
//   - .transition: "I just felt a state change"
//
// Each Mark stores timestamp + the live displayScore at time of tap. Post-session:
// the SessionSummarySheet shows tapped moments alongside the gauge trace and
// computes agreement: did "deepest" marks land on local maxima of the gauge?

enum MarkType: String, Codable {
    case deepest
    case shallowest
    case transition
}

struct Mark: Codable, Identifiable {
    var id: String { "\(time)_\(type.rawValue)" }
    let time: Double          // seconds from session start
    let type: MarkType
    let displayScore: Float   // ECDF display value at moment of tap (0-1)
    let depthZ: Float?        // raw z at moment of tap (nil if pre-calibration)
}

// Lightweight in-memory mark collector. Lives on Probe; flushed to SessionRecorder
// via a single addMark() call. Clears on session start.
final class MarkCollector: ObservableObject {
    @Published private(set) var marks: [Mark] = []
    @Published var lastMarkPulse: Date? = nil  // for UI feedback flash

    func add(time: Double, type: MarkType, display: Float, z: Float?) {
        marks.append(Mark(time: time, type: type, displayScore: display, depthZ: z))
        lastMarkPulse = Date()
    }

    func reset() {
        marks.removeAll()
        lastMarkPulse = nil
    }

    var snapshot: [Mark] { marks }
}

// Post-session agreement: % of "deepest" marks within top-25% of session gauge values.
// % of "shallowest" marks within bottom-25%. <70% agreement triggers recalibration prompt.
struct MarkAgreement {
    let deepestCount: Int
    let deepestInTop25: Int
    let shallowestCount: Int
    let shallowestInBottom25: Int

    var agreementPct: Float {
        let total = deepestCount + shallowestCount
        guard total > 0 else { return 1.0 }
        return Float(deepestInTop25 + shallowestInBottom25) / Float(total)
    }

    static func compute(marks: [Mark], sessionScores: [Float]) -> MarkAgreement {
        guard !sessionScores.isEmpty else {
            return MarkAgreement(deepestCount: 0, deepestInTop25: 0,
                                 shallowestCount: 0, shallowestInBottom25: 0)
        }
        let sorted = sessionScores.sorted()
        let p25 = sorted[max(0, min(sorted.count - 1, sorted.count / 4))]
        let p75 = sorted[max(0, min(sorted.count - 1, sorted.count * 3 / 4))]

        var deepest = 0, deepIn = 0, shallow = 0, shallowIn = 0
        for m in marks {
            switch m.type {
            case .deepest:
                deepest += 1
                if m.displayScore >= p75 { deepIn += 1 }
            case .shallowest:
                shallow += 1
                if m.displayScore <= p25 { shallowIn += 1 }
            case .transition:
                break  // not used in agreement metric
            }
        }
        return MarkAgreement(deepestCount: deepest, deepestInTop25: deepIn,
                             shallowestCount: shallow, shallowestInBottom25: shallowIn)
    }
}
