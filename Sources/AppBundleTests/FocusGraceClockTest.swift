@testable import AppBundle
import XCTest

@MainActor
final class FocusGraceClockTest: XCTestCase {
    func testGraceWindowsExpireIndependentlyAtTheirBoundaries() {
        var now = ContinuousClock().now
        let state = FocusStealingPreventionState(now: { now })
        XCTAssertFalse(state.isUserInitiatedFocusChange)
        XCTAssertFalse(state.hadRecentAppActivation)
        state.markUserInitiatedFocusChange()
        state.markRecentAppActivation()
        now = now.advanced(by: .milliseconds(499))
        XCTAssertTrue(state.isUserInitiatedFocusChange)
        XCTAssertTrue(state.hadRecentAppActivation)
        now = now.advanced(by: .milliseconds(1))
        XCTAssertTrue(state.isUserInitiatedFocusChange)
        XCTAssertFalse(state.hadRecentAppActivation)
        now = now.advanced(by: .milliseconds(500))
        XCTAssertFalse(state.isUserInitiatedFocusChange)
    }

    func testRepeatedUserActionExtendsGraceButAppActivationDoesNot() {
        var now = ContinuousClock().now
        let state = FocusStealingPreventionState(now: { now })
        state.markUserInitiatedFocusChange()
        now = now.advanced(by: .milliseconds(750))
        state.markUserInitiatedFocusChange()
        now = now.advanced(by: .milliseconds(999))
        XCTAssertTrue(state.isUserInitiatedFocusChange)
        state.markRecentAppActivation()
        now = now.advanced(by: .milliseconds(1))
        XCTAssertFalse(state.isUserInitiatedFocusChange)
        XCTAssertTrue(state.hadRecentAppActivation)
        state.reset()
        XCTAssertFalse(state.hadRecentAppActivation)
    }
}
