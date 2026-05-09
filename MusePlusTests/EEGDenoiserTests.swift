import XCTest
@testable import MusePlus

final class EEGDenoiserTests: XCTestCase {

    private let denoiser = EEGDenoiser()

    // MARK: - Helpers

    /// Generate 256-sample channel of all zeros.
    private func zeros() -> [Float] { [Float](repeating: 0.0, count: 256) }

    /// Generate a pure sine wave at `hz` Hz, 256 samples, 256 Hz sample rate.
    private func sine(hz: Float, amplitude: Float = 1.0) -> [Float] {
        (0..<256).map { n in
            amplitude * sin(2.0 * Float.pi * hz * Float(n) / 256.0)
        }
    }

    /// Four identical channels from the given channel signal.
    private func fourChannels(_ ch: [Float]) -> [[Float]] {
        [ch, ch, ch, ch]
    }

    // MARK: - Tests

    func testIdentityOnFlatSignal() throws {
        let window = fourChannels(zeros())
        let (cleaned, stats) = denoiser.denoise(window: window)

        XCTAssertEqual(cleaned.count, 4)
        for ch in cleaned {
            XCTAssertEqual(ch.count, 256)
            let rms = sqrt(ch.map { $0 * $0 }.reduce(0, +) / Float(ch.count))
            XCTAssertLessThan(rms, 1e-5, "Flat input should produce near-zero output")
        }
        // spikesRemoved should be 0 on a flat signal.
        XCTAssertEqual(stats.spikesRemoved, 0,
                       "No spikes expected on flat input")
    }

    func testIdentityOnSineWave() throws {
        // 10 Hz pure sine — lies within alpha band (8–12 Hz).
        let window = fourChannels(sine(hz: 10.0))
        let (cleaned, stats) = denoiser.denoise(window: window)

        XCTAssertEqual(cleaned.count, 4)
        // Alpha power ratio should be close to 1.0 (signal preserved).
        XCTAssertGreaterThanOrEqual(stats.alphaPowerRatio, 0.9,
            "Alpha power ratio should be >= 0.9 for pure 10 Hz sine")
        XCTAssertLessThanOrEqual(stats.alphaPowerRatio, 1.1,
            "Alpha power ratio should be <= 1.1 for pure 10 Hz sine")
    }

    func testSpikeRemoval() throws {
        // Inject a single 100σ spike at the center sample.
        var channel = sine(hz: 10.0, amplitude: 1.0)
        let spikeIdx = 128
        channel[spikeIdx] = 200.0   // >> typical amplitude ~ 1.0 => ~100σ spike

        let window = fourChannels(channel)
        let (_, stats) = denoiser.denoise(window: window)

        // Spike RMS reduction should be < 0.5 (at least 50% suppression).
        XCTAssertLessThan(stats.spikeRmsReduction, 0.5,
            "SWT should suppress a 100σ spike by at least 50% RMS")
        XCTAssertGreaterThan(stats.spikesRemoved, 0,
            "At least one spike should be reported removed")
    }

    func testWindowSizeEnforcement() throws {
        // Pass wrong dims: 4 channels × 100 samples instead of 256.
        // EEGDenoiser uses precondition() for wrong dims — expect fatal or graceful skip.
        // In unit test context we skip this test rather than crash the runner.
        // TODO: confirm API — if EEGDenoiser gains a throwing/returning-nil variant,
        //       replace XCTSkip with a real assertion.
        XCTSkip("denoise(window:) uses precondition() for wrong dims — " +
                "cannot test fatal precondition failure in XCTest without crash harness")
    }

    func testStatsBoundedRange() throws {
        // For a reasonable EEG-like signal the alphaPowerRatio should be in [0.5, 2.0].
        // Mix alpha + broad-band noise.
        let alphaSignal = sine(hz: 10.0, amplitude: 2.0)
        let noise: [Float] = (0..<256).map { _ in Float.random(in: -0.5...0.5) }
        let mixed: [Float] = zip(alphaSignal, noise).map(+)

        let window = fourChannels(mixed)
        let (_, stats) = denoiser.denoise(window: window)

        XCTAssertGreaterThanOrEqual(stats.alphaPowerRatio, 0.5,
            "alphaPowerRatio lower bound 0.5 violated")
        XCTAssertLessThanOrEqual(stats.alphaPowerRatio, 2.0,
            "alphaPowerRatio upper bound 2.0 violated")
    }
}
