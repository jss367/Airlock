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
/// place that closes or moves a window. Focus changes also prune immediately, so a visit can't be
/// missed when a command sequence or interrupted session leaves before the next read.
@MainActor
final class FocusAttentionState {
    private struct FocusSnapshot {
        let windowId: UInt32?
        let workspaceName: String
    }

    private var requests: [UInt32: FocusAttentionRequest] = [:]
    private final class DeferredRequest {
        weak var window: Window?
        let order: UInt64

        init(_ window: Window, order: UInt64) {
            self.window = window
            self.order = order
        }
    }

    private var deferredRequests: [UInt32: DeferredRequest] = [:]
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
        _ = resolveDeferredRequests()
        let workspace = window.nodeWorkspace
        guard isDeferringFocus, workspace != nil || window.parent === macosMinimizedWindowsContainer else { return }
        counter += 1
        requests[window.windowId] = workspace.map { FocusAttentionRequest(windowId: window.windowId, workspaceName: $0.name, order: counter) }
        deferredRequests[window.windowId] = workspace == nil ? DeferredRequest(window, order: counter) : nil
    }

    /// Live requests, most recent first
    var pending: [FocusAttentionRequest] {
        _ = resolveDeferredRequests()
        return requests.values.sorted { $0.order > $1.order }
    }

    func clear(windowId: UInt32) {
        requests[windowId] = nil
        deferredRequests[windowId] = nil
    }

    /// Focus sync precedes layout normalization. A restored window can still be in the global
    /// minimized container when its focus is denied, so keep the request until its workspace exists.
    func resolveDeferredRequests() -> Bool {
        // Observe focus before adding recovered requests: normalization changing the focus fallback
        // must not count as the user answering a request that has only just become resolvable.
        prune()
        guard isDeferringFocus else { return false }
        var resolved = false
        for (id, request) in deferredRequests {
            guard let window = request.window, window.isBound else {
                deferredRequests[id] = nil
                continue
            }
            guard let workspace = window.nodeWorkspace else { continue }
            requests[id] = FocusAttentionRequest(windowId: id, workspaceName: workspace.name, order: request.order)
            deferredRequests[id] = nil
            resolved = true
        }
        return resolved
    }

    func didChangeFocus() { _ = resolveDeferredRequests() }

    /// Renaming keeps the same workspace and does not answer its requests.
    func renameWorkspace(from oldName: String, to newName: String) {
        requests = requests.mapValues { request in
            request.workspaceName == oldName
                ? FocusAttentionRequest(windowId: request.windowId, workspaceName: newName, order: request.order)
                : request
        }
        if let seenFocus, seenFocus.workspaceName == oldName {
            self.seenFocus = FocusSnapshot(windowId: seenFocus.windowId, workspaceName: newName)
        }
    }

    func reset() {
        requests = [:]
        deferredRequests = [:]
        seenFocus = nil
    }

    private var isDeferringFocus: Bool {
        sessionCoordinator.isEnabled && config.enableWindowManagement && config.activePreventFocusStealing != .off
    }

    private func prune() {
        guard isDeferringFocus else { return reset() }
        let focus = focus
        let currentFocus = FocusSnapshot(windowId: focus.windowOrNil?.windowId, workspaceName: focus.workspace.name)
        let focusChanged = currentFocus.windowId != seenFocus?.windowId || currentFocus.workspaceName != seenFocus?.workspaceName
        let arrivedAt = focusChanged ? currentFocus.workspaceName : nil
        seenFocus = currentFocus
        requests = requests.filter { _, request in
            // The user went to the window, or to its workspace and picked something else
            request.workspaceName != arrivedAt &&
                // Still open, and still where it asked from
                Window.get(byId: request.windowId)?.nodeWorkspace?.name == request.workspaceName
        }
    }
}
