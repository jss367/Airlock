@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusFlashPredicateTest: XCTestCase {
    func testOff_neverFires() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .off,
            prevWorkspace: "A", currWorkspace: "B",
            prevAppId: "com.foo", currAppId: "com.bar",
            secondsSincePrev: 100, idleThreshold: 10,
        ))
    }

    func testEvery_alwaysFires() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .every,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossWorkspace_firesOnSwitch() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .crossWorkspace,
            prevWorkspace: "A", currWorkspace: "B",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossWorkspace_skipsSameWorkspace() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .crossWorkspace,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.bar",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossApp_firesOnAppChange() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .crossApp,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.bar",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossApp_skipsSameApp() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .crossApp,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testIdle_firesAfterThreshold() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .idle,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 11, idleThreshold: 10,
        ))
    }

    func testIdle_skipsBeforeThreshold() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .idle,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 5, idleThreshold: 10,
        ))
    }

    func testIdle_firesOnFirstEverFocus() {
        // No previous focus → secondsSincePrev = .infinity sentinel.
        XCTAssertTrue(shouldAutoFlash(
            mode: .idle,
            prevWorkspace: nil, currWorkspace: "A",
            prevAppId: nil, currAppId: "com.foo",
            secondsSincePrev: .infinity, idleThreshold: 10,
        ))
    }

    func testCrossWorkspace_firesOnFirstEverFocus() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .crossWorkspace,
            prevWorkspace: nil, currWorkspace: "A",
            prevAppId: nil, currAppId: "com.foo",
            secondsSincePrev: .infinity, idleThreshold: 10,
        ))
    }
}
