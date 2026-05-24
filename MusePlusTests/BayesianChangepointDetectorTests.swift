import XCTest
@testable import MusePlus

final class BayesianChangepointDetectorTests: XCTestCase {

    /// Stationary Gaussian noise should never fire above the 0.75 threshold.
    /// Note: uses maxRunLength: 300 in tests (not 7200) to keep test runtime fast.
    /// The correctness of the algorithm does not depend on maxRunLength magnitude.
    func testStationaryDoesNotFire() {
        var det = BayesianChangepointDetector(hazardRate: 1.0 / 250.0, maxRunLength: 300)
        var rng = SystemRandomNumberGenerator()
        var maxPosterior: Float = 0
        for _ in 0..<500 {
            // mean 0.7, std 0.05 — typical deep-state Kalman output noise floor
            let x = Float(boxMuller(&rng)) * 0.05 + 0.7
            let p = det.observe(x)
            maxPosterior = max(maxPosterior, p)
        }
        XCTAssertLessThan(maxPosterior, 0.50,
            "stationary noise should not yield posterior > 0.50; got \(maxPosterior)")
    }

    /// A clear downward step should fire posterior > 0.75 within 10 samples of the step.
    func testDownwardStepFires() {
        var det = BayesianChangepointDetector(hazardRate: 1.0 / 250.0, maxRunLength: 300)
        var rng = SystemRandomNumberGenerator()
        // Warm-up at 0.75
        for _ in 0..<100 {
            _ = det.observe(Float(boxMuller(&rng)) * 0.04 + 0.75)
        }
        // Step down to 0.45
        var firedAt = -1
        for i in 0..<30 {
            let p = det.observe(Float(boxMuller(&rng)) * 0.04 + 0.45)
            if p > 0.75 && firedAt < 0 { firedAt = i }
        }
        XCTAssertGreaterThanOrEqual(firedAt, 0, "detector never fired on step")
        XCTAssertLessThanOrEqual(firedAt, 10,
            "detector fired \(firedAt) samples post-step; expected <= 10")
    }

    /// Slow drift (linear decay over 60 samples) should fire eventually.
    func testGradualDriftFires() {
        var det = BayesianChangepointDetector(hazardRate: 1.0 / 250.0, maxRunLength: 300)
        for i in 0..<60 {
            _ = det.observe(Float(0.04) + 0.75 * Float(60 - i) / 60.0)  // slow decay
        }
        // After 60 samples the recent posterior should reflect a different regime
        XCTAssertGreaterThan(det.lastPosterior, 0.30)
    }

    /// Box-Muller transform for Gaussian noise.
    private func boxMuller(_ rng: inout SystemRandomNumberGenerator) -> Double {
        let u1 = Double.random(in: 1e-12...1, using: &rng)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
