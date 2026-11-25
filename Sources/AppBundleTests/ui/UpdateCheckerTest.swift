import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class UpdateCheckerTest: XCTestCase {
    func testOnlyBuildsWithFeedCanUpdate() {
        XCTAssertTrue(UpdateChecker.hasFeed(["SUFeedURL": "https://example.com/appcast.xml"]))
        XCTAssertFalse(UpdateChecker.hasFeed(["SUFeedURL": ""])) // Xcode Debug configuration
        XCTAssertFalse(UpdateChecker.hasFeed([:])) // build-debug.sh
        XCTAssertFalse(UpdateChecker.hasFeed(nil))
    }

    func testCheckIsUnavailableUntilUpdaterStarts() {
        XCTAssertFalse(UpdateChecker().canCheck)
    }

    func testUpdateRelaunchRestoresWindowsOnceOnTermination() {
        let center = NotificationCenter()
        var restores = 0
        let checker = UpdateChecker(notificationCenter: center, restoreWindows: { restores += 1 })

        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(restores, 0, "An ordinary quit already restores windows before terminating")

        checker.restoreWindowsOnTermination()
        checker.restoreWindowsOnTermination() // Sparkle asks again if the user delays the relaunch
        XCTAssertEqual(restores, 0, "Airlock still manages windows until it exits")

        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(restores, 1)
    }
}
