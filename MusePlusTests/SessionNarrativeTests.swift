import XCTest
@testable import MusePlus

final class SessionNarrativeTests: XCTestCase {

    func testZeroDeepFractionMentionsGate() {
        let rec = makeRecord(deepFraction: 0, ecdfMax: 0.94,
                             enterSustainedAtSession: 3,
                             enterThresholdAtSession: 0.65)
        let n = SessionNarrative.compose(from: rec)
        XCTAssertTrue(n.lines.contains { $0.contains("94") },
            "narrative must surface ecdfMax when no deep entry: \(n.lines)")
        XCTAssertTrue(n.lines.contains { $0.contains("3 seconds") || $0.contains("3-second") },
            "narrative must surface active gate seconds: \(n.lines)")
    }

    func testCrossoverFirstTimeAppearsWhenPresent() {
        let rec = makeRecord(deepFraction: 0.1, alphaThetaCrossoverCount: 3,
                             alphaThetaCrossoverFirstTime: 412.0)
        let n = SessionNarrative.compose(from: rec)
        XCTAssertTrue(n.lines.contains { $0.contains("theta") && $0.contains("alpha") },
            "narrative must mention crossover when count > 0: \(n.lines)")
    }

    func testCleanSignalWhenLowSpikes() {
        let rec = makeRecord(deepFraction: 0.2,
                             signalQualityMeanSpikes: 4.0,
                             signalQualityAlphaPowerRatio: 0.82)
        let n = SessionNarrative.compose(from: rec)
        XCTAssertTrue(n.lines.contains { $0.lowercased().contains("clean") || $0.lowercased().contains("good") },
            "low-spike sessions should be reported as clean: \(n.lines)")
    }

    func testNoNumericLeak() {
        // No raw decimals like "0.937" or "ecdf" jargon should appear.
        let rec = makeRecord(deepFraction: 0.3, ecdfMax: 0.937)
        let n = SessionNarrative.compose(from: rec)
        for line in n.lines {
            XCTAssertFalse(line.contains("ecdf"), "jargon leak: \(line)")
            XCTAssertFalse(line.contains("0.9"),  "raw decimal leak: \(line)")
        }
    }

    func testCalibrationQualityBranches() {
        let weak = makeRecord(calibrationBetaAttached: false)
        let strong = makeRecord(calibrationBetaAttached: true, calibrationBetaStd: 0.12)
        XCTAssertNotEqual(SessionNarrative.compose(from: weak).lines.first,
                          SessionNarrative.compose(from: strong).lines.first)
    }

    func testEmptyRecordDoesNotCrash() {
        let n = SessionNarrative.compose(from: SessionRecord(
            id: "x", startDate: Date(), endDate: nil,
            samples: [], episodes: [], fitEvents: []))
        XCTAssertGreaterThan(n.lines.count, 0)
    }

    // MARK: - Fixture builder

    private func makeRecord(
        deepFraction: Double? = 0,
        ecdfMax: Float? = nil,
        enterSustainedAtSession: Int? = 6,
        enterThresholdAtSession: Float? = 0.65,
        signalQualityMeanSpikes: Float? = nil,
        signalQualityAlphaPowerRatio: Float? = nil,
        alphaThetaCrossoverCount: Int? = 0,
        alphaThetaCrossoverFirstTime: Double? = nil,
        calibrationBetaAttached: Bool? = true,
        calibrationBetaStd: Float? = 0.15
    ) -> SessionRecord {
        var r = SessionRecord(id: "test", startDate: Date(), endDate: Date().addingTimeInterval(1200),
                              samples: [], episodes: [], fitEvents: [])
        r.deepFraction                  = deepFraction
        r.ecdfMax                       = ecdfMax
        r.enterSustainedAtSession       = enterSustainedAtSession
        r.enterThresholdAtSession       = enterThresholdAtSession
        r.signalQualityMeanSpikes       = signalQualityMeanSpikes
        r.signalQualityAlphaPowerRatio  = signalQualityAlphaPowerRatio
        r.alphaThetaCrossoverCount      = alphaThetaCrossoverCount
        r.alphaThetaCrossoverFirstTime  = alphaThetaCrossoverFirstTime
        r.calibrationBetaAttached       = calibrationBetaAttached
        r.calibrationBetaStd            = calibrationBetaStd
        return r
    }
}
