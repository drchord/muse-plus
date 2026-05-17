import XCTest
@testable import MusePlus

final class KalmanDepthTests: XCTestCase {

    func testKalmanConvergesToTrueDepth() {
        var k = KalmanDepth()
        // Feed 40 observations at true depth 0.7
        for _ in 0..<40 { _ = k.update(z: 0.7) }
        XCTAssertEqual(k.depth, 0.7, accuracy: 0.01, "Kalman should converge within 1% of true depth after 40 observations")
    }

    func testKalmanClampsOutliers() {
        var k = KalmanDepth()
        _ = k.update(z: 0.5)
        let depthBefore = k.depth
        // Large outlier — innovation is clipped to ±0.3, limiting the state jump
        _ = k.update(z: 2.0)
        XCTAssertLessThanOrEqual(k.depth, 1.0, "Kalman depth must not exceed 1.0")
        XCTAssertLessThan(k.depth - depthBefore, 0.15,
                          "Outlier step should be small (< 0.15) due to ±0.3 innovation clip")
    }

    func testKalmanVelocityPositiveOnRise() {
        var k = KalmanDepth()
        for i in 0..<30 { _ = k.update(z: Float(i) * 0.02) }  // rising signal 0→0.58
        XCTAssertGreaterThan(k.vel, 0, "Velocity should be positive during rising depth")
    }

    func testKalmanReset() {
        var k = KalmanDepth()
        for _ in 0..<20 { _ = k.update(z: 0.9) }
        k.reset()
        XCTAssertEqual(k.depth, 0.5, accuracy: 0.001)
        XCTAssertEqual(k.vel,   0.0, accuracy: 0.001)
    }

    func testQDMutable() {
        var k = KalmanDepth()
        let originalQD = k.qD
        k.qD = 0.010
        XCTAssertEqual(k.qD, 0.010, accuracy: 0.0001, "qD must be mutable")
        XCTAssertNotEqual(k.qD, originalQD)
    }

    func testHigherQDTracksFaster() {
        var kSlow = KalmanDepth()
        kSlow.qD = 0.0005
        var kFast = KalmanDepth()
        kFast.qD = 0.015
        for _ in 0..<10 { _ = kSlow.update(z: 0.9) }
        for _ in 0..<10 { _ = kFast.update(z: 0.9) }
        XCTAssertGreaterThan(kFast.depth, kSlow.depth,
                             "Higher qD should track faster (closer to 0.9 after 10 steps)")
    }
}
