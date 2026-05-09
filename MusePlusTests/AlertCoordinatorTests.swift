import XCTest
@testable import MusePlus

// MARK: - AlertCoordinatorTests
//
// AlertCoordinator uses CHHapticEngine, ChimeEngine.shared, and
// UNUserNotificationCenter. No DI seams exist on the class, so
// these are integration-style no-crash tests.
//
// Note: CoreHaptics fires only on physical devices. On simulator the haptic
// engine init fails silently (guarded internally), so tests still pass.

final class AlertCoordinatorTests: XCTestCase {

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        // Nothing to reset — AlertCoordinator.shared is a singleton.
    }

    override func tearDown() async throws {
        // Nothing to tear down.
    }

    // MARK: - Tests

    func testSessionPausedFiresWithoutCrash() throws {
        // Each PauseReason variant must not crash the coordinator.
        let reasons: [PauseReason] = [
            .bleDrop,
            .audioInterruption,
            .contactLost,
            .lowBattery,
            .suspended
        ]
        for reason in reasons {
            // If this throws or traps, the test fails with a crash report.
            AlertCoordinator.shared.sessionPaused(reason: reason)
        }
        XCTAssertTrue(true, "sessionPaused(reason:) must not crash for any PauseReason")
    }

    func testSessionResumedFiresWithoutCrash() throws {
        AlertCoordinator.shared.sessionResumed()
        XCTAssertTrue(true, "sessionResumed() must not crash")
    }

    func testSessionEndedFailureFiresWithoutCrash() throws {
        AlertCoordinator.shared.sessionEndedFailure(reason: "unit-test")
        XCTAssertTrue(true, "sessionEndedFailure(reason:) must not crash")
    }

    func testSessionEndedSuccessFiresWithoutCrash() throws {
        AlertCoordinator.shared.sessionEndedSuccess(durationMin: 20.0)
        XCTAssertTrue(true, "sessionEndedSuccess(durationMin:) must not crash")
    }

    func testRequestAuthorizationDoesNotThrow() async throws {
        // requestAuthorization() calls UNUserNotificationCenter.requestAuthorization.
        // On simulator this returns a denied status silently — no throw expected.
        await AlertCoordinator.shared.requestAuthorization()
        XCTAssertTrue(true, "requestAuthorization() must not throw")
    }

    // TODO: confirm API — AlertCoordinator does not expose DI for CHHapticEngine
    // or UNUserNotificationCenter. If a future refactor adds init(hapticEngine:center:),
    // replace the no-crash tests above with mock-based assertions that the correct
    // methods were called on each channel.
}
