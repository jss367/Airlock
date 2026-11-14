@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceOverviewFocusMonitorTest: XCTestCase {
    func testFocusChangesCloseTheOverview() {
        let appNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let monitor = WorkspaceOverviewFocusMonitor(
            appNotifications: appNotifications,
            workspaceNotifications: workspaceNotifications,
        )
        defer { monitor.stop() }
        var closes = 0
        monitor.start { closes += 1 }

        appNotifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(closes, 1)
        // This also fires when Airlock was already inactive at invocation.
        workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(closes, 2)
    }

    func testAirlockActivatingForTheOverviewKeepsItOpen() {
        let notifications = NotificationCenter()
        let monitor = WorkspaceOverviewFocusMonitor(appNotifications: notifications, workspaceNotifications: notifications)
        defer { monitor.stop() }
        var closes = 0
        monitor.start { closes += 1 }

        // The test process stands in for Airlock
        notifications.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current],
        )
        XCTAssertEqual(closes, 0)
    }

    func testStoppedMonitorIgnoresFocusChanges() {
        let notifications = NotificationCenter()
        let monitor = WorkspaceOverviewFocusMonitor(
            appNotifications: notifications,
            workspaceNotifications: notifications,
        )
        var closes = 0
        monitor.start { closes += 1 }
        monitor.stop()

        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(closes, 0)
    }

    func testRestartReplacesPreviousObservers() {
        let notifications = NotificationCenter()
        let monitor = WorkspaceOverviewFocusMonitor(
            appNotifications: notifications,
            workspaceNotifications: notifications,
        )
        defer { monitor.stop() }
        var oldCloses = 0
        var newCloses = 0
        monitor.start { oldCloses += 1 }
        monitor.start { newCloses += 1 }

        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(oldCloses, 0)
        XCTAssertEqual(newCloses, 1)
    }
}
