@testable import AppBundle
import AppKit
import Common
import XCTest

/// Two Google Chrome windows on two workspaces of the same monitor made Airlock flip between those
/// workspaces about twice a second until another app was activated. The trigger field in the
/// `airlock subscribe` stream alternated perfectly between `ax(AXFocusedWindowChanged)` and
/// `macos-focus-sync via ax(AXMoved)`: switching to one workspace parks the other workspace's
/// window in a corner, the app then reports that parked window as its focused window, and the
/// session started by the move adopted it, which switched workspaces and parked the first window.
///
/// The move is what has to stop being read as a focus change. An app has one focused window, so any
/// app with windows on two workspaces can drive this.
final class FocusSyncOnGeometryEventsTest: XCTestCase {
    func testMoveAndResizeAreNotEvidenceThatFocusChanged() {
        XCTAssertFalse(RefreshSessionEvent.ax(kAXMovedNotification as String).mayHaveChangedFocus)
        XCTAssertFalse(RefreshSessionEvent.ax(kAXResizedNotification as String).mayHaveChangedFocus)
    }

    /// The fix must not cost Airlock the focus changes it exists to track. In particular the other
    /// half of the loop above is a genuine focus change that `prevent-focus-stealing` decides on,
    /// and it still has to reach `updateFocusCache`.
    func testRealFocusChangesStillSync() {
        let events: [RefreshSessionEvent] = [
            .ax(kAXFocusedWindowChangedNotification as String),
            .ax(kAXUIElementDestroyedNotification as String),
            .ax(kAXWindowMiniaturizedNotification as String),
            .ax(kAXWindowDeminiaturizedNotification as String),
            .globalObserver("NSWorkspaceDidActivateApplicationNotification"),
            .globalObserverLeftMouseUp,
            .hotkeyBinding,
            .menuBarButton,
            .startup,
            .configAutoReload,
            .resetManipulatedWithMouse,
            .onFocusChanged,
            .onFocusedMonitorChanged,
            .onModeChanged,
            .onWindowDetected,
        ]
        for event in events {
            XCTAssertTrue(event.mayHaveChangedFocus, "\(event) should still sync focus from macOS")
        }
    }
}
