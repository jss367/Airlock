import AppKit
import Common

/// The app's event coordinator owns refresh cancellation, pending evidence, and the native focus
/// cache together. Independent instances let tests exercise asynchronous ordering without globals.
@MainActor let focusEvents = FocusEventCoordinator()

@MainActor func resetFocusCacheForTests() { focusEvents.reset() }

/// A refresh session syncs focus from macOS before it runs anything, so the session's own trigger
/// would blame whatever woke Airlock up — including a query command that cannot move focus at all.
/// Say plainly that macOS moved the focus, and keep the session as the "noticed during" qualifier.
func focusChangeTrigger(sessionTrigger: String?, syncedFromMacOs: Bool) -> String? {
    guard syncedFromMacOs else { return sessionTrigger }
    return sessionTrigger.map { "macos-focus-sync via \($0)" } ?? "macos-focus-sync"
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
/// Returns whether it took a focus change from macOS, which the caller passes to `refreshModel` so
/// the change is reported as macOS's rather than the session's. Deliberately a return value and not
/// stored state: an optimistic refresh can be cancelled between here and the report, and a stored
/// marker would survive the cancellation to mislabel whatever the next session reports.
@MainActor func updateFocusCache(_ nativeFocused: Window?) -> Bool {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return false
    }
    // Record this even when the change below gets blocked. macOS did make the window key, and a stale
    // value lets MacApp.nativeFocus take its activate-only shortcut, which leaves a same-app stealer key
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
    var syncedFromMacOs = false
    if nativeFocused?.windowId != focusEvents.lastKnownNativeFocusedWindowId {
        if shouldAllowFocusChange(to: nativeFocused) {
            syncedFromMacOs = true
            _ = nativeFocused?.focusWindow()
            focusEvents.lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        } else {
            // Refocus the previously focused window to resist the steal
            if let currentWindow = focus.windowOrNil {
                currentWindow.nativeFocus()
            } else if !isUnitTest && !serverArgs.isReadOnly {
                // The focused workspace is empty, so there is no window to hand key focus back to.
                // Take it ourselves: otherwise the stealer stays key and receives keystrokes
                // while Airlock believes an empty workspace is focused
                NSApp.activate(ignoringOtherApps: true)
            }
            return false
        }
    }
    return syncedFromMacOs
}
