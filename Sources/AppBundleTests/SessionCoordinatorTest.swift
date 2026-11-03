@testable import AppBundle
import Combine
import XCTest

@MainActor
final class SessionCoordinatorTest: XCTestCase {
    func testReservedInvocationDoesNotSupersedePendingEnableUntilItExecutesEnable() throws {
        let coordinator = SessionCoordinator()
        let pending = coordinator.beginEnableIntent()
        let later = coordinator.reserveInvocationOrder()
        XCTAssertTrue(coordinator.isCurrent(pending))
        XCTAssertNoThrow(try coordinator.validateInvocation(later))
        XCTAssertTrue(coordinator.acceptEnableIntent(later))
        XCTAssertThrowsError(try coordinator.validateInvocation(pending))
        XCTAssertFalse(coordinator.acceptEnableIntent(pending))
        XCTAssertTrue(coordinator.isCurrent(later))
    }

    func testEnabledSessionStaysInvalidAfterPauseAndResume() {
        let coordinator = SessionCoordinator()
        let captured = coordinator.latestEnableIntent
        _ = coordinator.beginEnableIntent()
        coordinator.setEnabled(false)
        _ = coordinator.beginEnableIntent()
        coordinator.setEnabled(true)
        XCTAssertThrowsError(try coordinator.validateEnabledSession(captured))
        XCTAssertNoThrow(try coordinator.validateEnabledSession(coordinator.latestEnableIntent))
    }

    func testTrayObservesTheCoordinatorRunningState() {
        let original = sessionCoordinator.isEnabled
        defer { sessionCoordinator.setEnabled(original) }
        let tray = TrayMenuModel.shared
        var changes = 0
        let observation = tray.objectWillChange.sink { changes += 1 }
        sessionCoordinator.setEnabled(!original)
        XCTAssertEqual(tray.isEnabled, !original)
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(observation) {}
    }
}
