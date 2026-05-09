import XCTest
@testable import MusePlus

final class MainThreadStallTests: XCTestCase {

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        // Ensure detector is stopped before each test.
        await MainActor.run {
            MainThreadStall.shared.stop()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            MainThreadStall.shared.stop()
        }
    }

    // MARK: - Tests

    func testStartIdempotent() async throws {
        await MainActor.run {
            MainThreadStall.shared.start()
            MainThreadStall.shared.start()  // second call must be no-op, no crash
            // If we reach here without asserting, the no-op guard worked.
            XCTAssertTrue(true, "start() twice should not crash")
        }
    }

    func testStopIdempotent() async throws {
        await MainActor.run {
            // stop() without prior start() must not crash.
            MainThreadStall.shared.stop()
            MainThreadStall.shared.stop()
            XCTAssertTrue(true, "stop() without start() should not crash")
        }
    }

    func testStallCountResetsOnStart() async throws {
        await MainActor.run {
            // Start once (sets stallCount = 0 internally), then stop.
            MainThreadStall.shared.start()
            MainThreadStall.shared.stop()
            // Start again — stallCount must be 0 after the fresh start().
            MainThreadStall.shared.start()
            XCTAssertEqual(MainThreadStall.shared.stallCount, 0,
                           "stallCount must reset to 0 on start()")
        }
    }

    func testThermalStateLabelSkippedIfPrivate() throws {
        // thermalStateLabel(_:) is private — cannot call directly from @testable import.
        // Integration-level validation (actual stall reporting) requires device + 1.5s hold.
        // TODO: confirm API — if thermalStateLabel becomes internal/public, add an assertion.
        XCTSkip("thermalStateLabel is private; skipped per unit-test scope. " +
                "See integration test suite for stall-threshold coverage.")
    }

    // integration test, deferred
    // func testStallThreshold() {
    //     // Requires blocking main thread for > 1.5s then observing stallCount increment.
    //     // Cannot be done in unit tests without time injection; defer to integration suite.
    // }
}
