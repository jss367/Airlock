import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// Set when the focus change about to be reported came from macOS (an app activated itself, the user
/// clicked something) rather than from anything Airlock ran. Consumed by `checkOnFocusChangedCallbacks`,
/// which always runs immediately after `updateFocusCache` in the same refresh session.
@MainActor private var focusSyncedFromMacOs = false

/// Reads and clears `focusSyncedFromMacOs`, returning the `trigger` to report for this focus change.
@MainActor func consumeFocusChangeTrigger() -> String? {
    let syncedFromMacOs = focusSyncedFromMacOs
    focusSyncedFromMacOs = false
    return focusChangeTrigger(sessionTrigger: refreshSessionEvent?.trigger, syncedFromMacOs: syncedFromMacOs)
}

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
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if shouldAllowFocusChange(to: nativeFocused) {
            focusSyncedFromMacOs = true
            _ = nativeFocused?.focusWindow()
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        } else {
            // Refocus the previously focused window to resist the steal
            if let currentWindow = focus.windowOrNil {
                currentWindow.nativeFocus()
            }
            return
        }
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
