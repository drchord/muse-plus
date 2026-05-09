import XCTest
@testable import MusePlus

final class SessionTimerTests: XCTestCase {

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        await MainActor.run {
            SessionTimer.shared.cancel()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            SessionTimer.shared.cancel()
        }
    }

    // MARK: - Tests

    func testAllowedDurationsContains20MinPreset() throws {
        XCTAssertTrue(SessionTimer.allowedDurations.contains(20),
                      "allowedDurations must include 20-minute preset (B83 spec)")
    }

    func testAllowedDurationsIsNonEmpty() throws {
        XCTAssertFalse(SessionTimer.allowedDurations.isEmpty,
                       "allowedDurations must not be empty")
    }

    func testStartIsIdempotent() async throws {
        await MainActor.run {
            SessionTimer.shared.start()
            let remainingAfterFirst = SessionTimer.shared.remainingSec
            SessionTimer.shared.start()  // second call must be no-op
            XCTAssertTrue(SessionTimer.shared.isRunning,
                          "isRunning must stay true after duplicate start()")
            XCTAssertEqual(SessionTimer.shared.remainingSec, remainingAfterFirst,
                           "remainingSec must not change on idempotent start()")
        }
    }

    func testCancelClearsState() async throws {
        await MainActor.run {
            SessionTimer.shared.start()
            XCTAssertTrue(SessionTimer.shared.isRunning)
            SessionTimer.shared.cancel()
            XCTAssertFalse(SessionTimer.shared.isRunning,
                           "isRunning must be false after cancel()")
            XCTAssertEqual(SessionTimer.shared.remainingSec, 0,
                           "remainingSec must be 0 after cancel()")
        }
    }

    func testCancelWithoutStartIsIdempotent() async throws {
        await MainActor.run {
            // cancel() without prior start() must not crash.
            SessionTimer.shared.cancel()
            XCTAssertFalse(SessionTimer.shared.isRunning)
            XCTAssertEqual(SessionTimer.shared.remainingSec, 0)
        }
    }

    func testRemainingSecInitialisesFromSelectedDuration() async throws {
        await MainActor.run {
            SessionTimer.shared.selectedDurationMin = 10
            SessionTimer.shared.start()
            XCTAssertEqual(SessionTimer.shared.remainingSec, 10 * 60,
                           "remainingSec must equal selectedDurationMin × 60 at start")
        }
    }

    func testOnExpireFires() async throws {
        // Firing the real timer requires waiting selectedDurationMin × 60 seconds.
        // That is not viable in a unit test. Test that the closure property is
        // assignable and not called before the timer expires.
        // TODO: confirm API — if SessionTimer gains a testable clock injection,
        //       replace XCTSkip with an expectation on onExpire.
        await MainActor.run {
            var fired = false
            SessionTimer.shared.onExpire = { fired = true }
            SessionTimer.shared.selectedDurationMin = 5
            SessionTimer.shared.start()
            // Immediately: onExpire must NOT have fired.
            XCTAssertFalse(fired, "onExpire must not fire at start time")
            SessionTimer.shared.cancel()
            SessionTimer.shared.onExpire = nil
        }
    }
}
