import Combine
import Common

/// A focus change that `prevent-focus-stealing` refused. The window still wants the user, so the
/// block is a deferral: the menu bar marks its workspace, and `focus-attention` goes there.
struct FocusAttentionRequest: Equatable {
    let windowId: UInt32
    /// Where the window was when it asked. A window that has moved since is no longer waiting there
    let workspaceName: String
    /// Higher is more recent
    let order: UInt64
}

@MainActor let focusAttention = FocusAttentionState()

/// Requests are validated against the live tree on every read instead of being cleared from each
/// place that closes or moves a window, or moves focus. A stale marker can't outlive its cause.
@MainActor
final class FocusAttentionState {
    private struct FocusSnapshot: Equatable {
        let windowId: UInt32?
        let workspaceName: String
    }

    private var requests: [UInt32: FocusAttentionRequest] = [:]
    private var counter: UInt64 = 0
    /// Focus as of the last look. A request ends when focus arrives on its workspace, and in
    /// `always` mode the blocked window can already be on the focused workspace, so "is focused"
    /// can't tell the two apart. "Focus moved, and landed there" can.
    private var seenFocus: FocusSnapshot?
    private var pauseObservation: AnyCancellable?

    init() {
        // Nothing reads the requests while paused, so reads alone would let them survive a pause
        pauseObservation = sessionCoordinator.$isEnabled.sink { [weak self] isEnabled in
            if !isEnabled { MainActor.assumeIsolated { self?.reset() } }
        }
    }

    /// `window` was just denied focus
    func record(_ window: Window) {
        prune()
        guard isDeferringFocus, let workspace = window.nodeWorkspace else { return }
        counter += 1
        requests[window.windowId] = FocusAttentionRequest(windowId: window.windowId, workspaceName: workspace.name, order: counter)
    }

    /// Live requests, most recent first
    var pending: [FocusAttentionRequest] {
        prune()
        return requests.values.sorted { $0.order > $1.order }
    }

    func clear(windowId: UInt32) { requests[windowId] = nil }

    func reset() {
        requests = [:]
        seenFocus = nil
    }

    private var isDeferringFocus: Bool {
        sessionCoordinator.isEnabled && config.enableWindowManagement && config.preventFocusStealing != .off
    }

    private func prune() {
        guard isDeferringFocus else { return reset() }
        let focus = focus
        let currentFocus = FocusSnapshot(windowId: focus.windowOrNil?.windowId, workspaceName: focus.workspace.name)
        let arrivedAt = currentFocus != seenFocus ? currentFocus.workspaceName : nil
        seenFocus = currentFocus
        requests = requests.filter { _, request in
            // The user went to the window, or to its workspace and picked something else
            request.workspaceName != arrivedAt &&
                // Still open, and still where it asked from
                Window.get(byId: request.windowId)?.nodeWorkspace?.name == request.workspaceName
        }
    }
}
