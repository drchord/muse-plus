import XCTest
@testable import MusePlus

final class HRVPipelineTests: XCTestCase {

    private let testRR: [Double] = [0.8, 0.9, 0.7, 0.85, 0.75, 0.82, 0.78, 0.88, 0.72, 0.84]

    func testSDNN() {
        let mean = testRR.reduce(0, +) / Double(testRR.count)
        let variance = testRR.map { pow($0 - mean, 2) }.reduce(0, +) / Double(testRR.count)
        let expectedSDNN = sqrt(variance)
        let computed = HRVPipeline.computeSDNN(testRR)
        XCTAssertEqual(computed, expectedSDNN, accuracy: 0.0001, "SDNN must match hand-computed value")
    }

    func testSD1() {
        let diffs = zip(testRR.dropFirst(), testRR).map { pow($0 - $1, 2) }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        let expectedSD1 = rmssd / sqrt(2.0)
        let computed = HRVPipeline.computeSD1(testRR)
        XCTAssertEqual(computed!, expectedSD1, accuracy: 0.0001)
    }

    func testSD2() {
        let mean = testRR.reduce(0, +) / Double(testRR.count)
        let sdnn = sqrt(testRR.map { pow($0 - mean, 2) }.reduce(0, +) / Double(testRR.count))
        let diffs = zip(testRR.dropFirst(), testRR).map { pow($0 - $1, 2) }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        let inner = 2 * pow(sdnn, 2) - pow(rmssd, 2) / 2
        XCTAssertGreaterThan(inner, 0, "inner must be positive for healthy RR series")
        let expectedSD2 = sqrt(inner)
        let computed = HRVPipeline.computeSD2(testRR)
        XCTAssertEqual(computed!, expectedSD2, accuracy: 0.0001)
    }

    func testSD2NilOnNegativeInner() {
        let degenerate = [Double](repeating: 0.8, count: 9) + [1.5]
        XCTAssertNil(HRVPipeline.computeSD2(degenerate), "SD2 must be nil if inner term is negative")
    }
}
