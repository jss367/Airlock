@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class MissionControlCaptureMonitorTest: XCTestCase {
    func testFocusChangesCancelPendingCapture() {
        let appNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let monitor = MissionControlCaptureMonitor(
            appNotifications: appNotifications,
            workspaceNotifications: workspaceNotifications,
        )
        defer { monitor.stop() }
        var cancellations = 0
        monitor.start { cancellations += 1 }

        appNotifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(cancellations, 1)
        // This also fires when Airlock was already inactive at invocation.
        workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(cancellations, 2)
    }

    func testStoppedCaptureDoesNotCancelSubsequentPanelActivation() {
        let notifications = NotificationCenter()
        let monitor = MissionControlCaptureMonitor(
            appNotifications: notifications,
            workspaceNotifications: notifications,
        )
        var cancellations = 0
        monitor.start { cancellations += 1 }
        monitor.stop()

        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(cancellations, 0)
    }

    func testNewCaptureReplacesPreviousObservers() {
        let notifications = NotificationCenter()
        let monitor = MissionControlCaptureMonitor(
            appNotifications: notifications,
            workspaceNotifications: notifications,
        )
        defer { monitor.stop() }
        var oldCancellations = 0
        var newCancellations = 0
        monitor.start { oldCancellations += 1 }
        monitor.start { newCancellations += 1 }

        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(oldCancellations, 0)
        XCTAssertEqual(newCancellations, 1)
    }
}
