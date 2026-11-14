import AppKit
import Common
import Foundation

/// Owns the two independent grace windows. A monotonic clock keeps wall-clock adjustments from
/// extending or truncating them; tests can advance time without sleeping.
@MainActor
final class FocusStealingPreventionState {
    private let now: () -> ContinuousClock.Instant
    private var userInitiatedDeadline: ContinuousClock.Instant?
    private var appActivationDeadline: ContinuousClock.Instant?

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.now = now
    }

    func markUserInitiatedFocusChange() {
        userInitiatedDeadline = now().advanced(by: .seconds(1))
    }

    func markRecentAppActivation() {
        appActivationDeadline = now().advanced(by: .milliseconds(500))
    }

    var isUserInitiatedFocusChange: Bool { userInitiatedDeadline.map { now() < $0 } ?? false }
    var hadRecentAppActivation: Bool { appActivationDeadline.map { now() < $0 } ?? false }

    func reset() {
        userInitiatedDeadline = nil
        appActivationDeadline = nil
    }
}

@MainActor private let focusStealingPrevention = FocusStealingPreventionState()

/// Allow notifications caused by a user action to arrive before protecting focus again.
@MainActor func markUserInitiatedFocusChange() { focusStealingPrevention.markUserInitiatedFocusChange() }
@MainActor var isUserInitiatedFocusChange: Bool { focusStealingPrevention.isUserInitiatedFocusChange }

/// An app activation helps identify app-initiated space changes, but is not itself user intent.
@MainActor func markRecentAppActivation() { focusStealingPrevention.markRecentAppActivation() }
@MainActor var hadRecentAppActivation: Bool { focusStealingPrevention.hadRecentAppActivation }

@MainActor func resetFocusStealingPreventionForTests() {
    focusStealingPrevention.reset()
    focusAttention.reset()
}

/// Determines whether a focus change to `newWindow` should be blocked based on the
/// `prevent-focus-stealing` config setting.
///
/// Returns `true` if the focus change should be allowed, `false` if it should be blocked.
/// A blocked window is recorded in `focusAttention`, so the user can still get to it.
@MainActor
func shouldAllowFocusChange(to newWindow: Window?) -> Bool {
    guard config.enableWindowManagement else { return true }
    let mode = config.preventFocusStealing
    guard mode != .off else { return true }
    guard !isUserInitiatedFocusChange else { return true }
    // At startup, macOS's focus is where the user left it before Airlock ran. There is no Airlock
    // focus yet for anything to steal from
    guard !isStartup else { return true }
    guard let newWindow else { return true }

    let currentFocus = focus
    // cmd-h on the focused app makes macOS hand focus to the next app. On the same workspace that is
    // where focus belongs now. A change to another workspace is still blocked, but `updateFocusCache`
    // doesn't push it back to the hidden window
    if let currentWindow = currentFocus.windowOrNil, currentWindow.staysHiddenByMacos,
       newWindow.nodeWorkspace == currentFocus.workspace
    {
        return true
    }

    switch mode {
        case .off:
            return true
        case .crossWorkspace:
            // Block if the new window is on a different workspace
            guard let newWorkspace = newWindow.nodeWorkspace else { return true }
            return newWorkspace == currentFocus.workspace
        case .always:
            // Block if the newly focused window differs from the current one at all
            guard let currentWindow = currentFocus.windowOrNil else { return true }
            return newWindow.windowId == currentWindow.windowId
    }
}

extension Window {
    /// The window's app is hidden by macOS (cmd-h), and Airlock isn't going to unhide it. Focusing the
    /// window would activate the app and undo the hide
    @MainActor var staysHiddenByMacos: Bool { !config.automaticallyUnhideMacosHiddenApps && isMacosAppHidden }
}

extension Workspace {
    /// The window to give focus back to when the focused one can't take it, because its app was hidden
    @MainActor var mostRecentShownWindow: Window? {
        allLeafWindowsRecursive
            .filter { $0.layoutReason == .standard && !$0.staysHiddenByMacos }
            .max(by: { $0.focusRecency < $1.focusRecency })
    }
}
