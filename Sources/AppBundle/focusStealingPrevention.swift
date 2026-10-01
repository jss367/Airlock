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

@MainActor func resetFocusStealingPreventionForTests() { focusStealingPrevention.reset() }

/// Determines whether a focus change to `newWindow` should be blocked based on the
/// `prevent-focus-stealing` config setting.
///
/// Returns `true` if the focus change should be allowed, `false` if it should be blocked.
@MainActor
func shouldAllowFocusChange(to newWindow: Window?) -> Bool {
    guard config.enableWindowManagement else { return true }
    let mode = config.preventFocusStealing
    guard mode != .off else { return true }
    guard !isUserInitiatedFocusChange else { return true }
    guard let newWindow else { return true }

    let currentFocus = focus

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
