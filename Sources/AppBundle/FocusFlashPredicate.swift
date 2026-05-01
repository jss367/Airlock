import Common

/// Pure decision: given a focus-change event's "before/after" snapshot and the
/// configured mode, should we fire an auto-flash?
///
/// `secondsSincePrev` is the time since the *previous focus event* (not since
/// the previous flash). Pass `.infinity` for the very first focus event ever
/// (no previous focus). `nil` workspace / app id values are also legitimate
/// for the first event, and indicate "no previous data" — they compare unequal
/// to any non-nil current value, so `cross-workspace` and `cross-app` will fire
/// on the first event.
func shouldAutoFlash(
    mode: FocusFlashMode,
    prevWorkspace: String?,
    currWorkspace: String?,
    prevAppId: String?,
    currAppId: String?,
    secondsSincePrev: Double,
    idleThreshold: Int,
) -> Bool {
    switch mode {
        case .off:
            return false
        case .every:
            return true
        case .crossWorkspace:
            return prevWorkspace != currWorkspace
        case .crossApp:
            return prevAppId != currAppId
        case .idle:
            return secondsSincePrev >= Double(idleThreshold)
    }
}
