import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// Whether some event that could have moved focus is still waiting to be answered by a focus sync.
///
/// Sessions coalesce: `scheduleRefreshSession` cancels the session in flight, and the session it
/// cancels may be one that had a focus change to pick up and had not reached `updateFocusCache`
/// yet. When the event doing the cancelling is a window move or resize, which carries no focus
/// evidence of its own, the focus change would otherwise be dropped rather than merely
/// re-attributed — and nothing guarantees a later event comes along to repair it. So the evidence
/// outlives the session that carried it and is answered by whichever session gets there first.
@MainActor private var pendingFocusEvidence = false

@MainActor func noteFocusEvidence(of event: RefreshSessionEvent) {
    if event.mayHaveChangedFocus { pendingFocusEvidence = true }
}

/// Reads the evidence and clears it in one step. Call it immediately before `updateFocusCache` with
/// no suspension point in between, so a cancellation can't land between the two and lose it.
@MainActor func consumeFocusEvidence() -> Bool {
    defer { pendingFocusEvidence = false }
    return pendingFocusEvidence
}

@MainActor func resetFocusEvidenceForTests() {
    pendingFocusEvidence = false
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
