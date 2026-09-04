import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

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
    var syncedFromMacOs = false
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if shouldAllowFocusChange(to: nativeFocused) {
            syncedFromMacOs = true
            _ = nativeFocused?.focusWindow()
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        } else {
            // Refocus the previously focused window to resist the steal
            if let currentWindow = focus.windowOrNil {
                currentWindow.nativeFocus()
            }
            return false
        }
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
    return syncedFromMacOs
}
