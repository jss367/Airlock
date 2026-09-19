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
@MainActor
final class FocusSyncOnGeometryEventsTest: XCTestCase {
    override func setUp() async throws { resetFocusEvidenceForTests() }

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

    /// Sessions coalesce, so a move arriving right behind a focus change cancels the session that
    /// was about to pick that focus change up. The move session has to answer for it, or the focus
    /// change is lost outright — a same-app keyboard switch has no later event guaranteed to repair
    /// it.
    func testAGeometryEventAnswersFocusEvidenceItCancelled() {
        noteFocusEvidence(of: .ax(kAXFocusedWindowChangedNotification as String))
        noteFocusEvidence(of: .ax(kAXMovedNotification as String))
        XCTAssertTrue(consumeFocusEvidence(), "the cancelled focus change must survive the move")
    }

    /// Only a session that answers the evidence may spend it. A light session syncs focus on its own
    /// and cannot be cancelled by a refresh scheduled behind it, so if it consumed, it would consume
    /// on a stale snapshot and starve the refresh that recorded the evidence.
    func testEvidenceOutlivesSessionsThatDontAnswerIt() {
        noteFocusEvidence(of: .hotkeyBinding)
        noteFocusEvidence(of: .ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(consumeFocusEvidence(), "the newer focus change must still be there to sync")
    }

    func testEvidenceIsSpentOnce() {
        noteFocusEvidence(of: .ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(consumeFocusEvidence())
        XCTAssertFalse(consumeFocusEvidence(), "a spent focus change must not sync twice")
    }

    /// The loop this whole change exists to break: Airlock parks a window, the park fires a move,
    /// and that move must not reach for macOS's focus on its own.
    func testMovesAloneNeverProduceEvidence() {
        noteFocusEvidence(of: .ax(kAXMovedNotification as String))
        noteFocusEvidence(of: .ax(kAXResizedNotification as String))
        XCTAssertFalse(consumeFocusEvidence())
    }
}
