import AppKit
import Common

enum EffectiveLeaf {
    case window(Window)
    case emptyWorkspace(Workspace)
}
extension LiveFocus {
    var asLeaf: EffectiveLeaf {
        if let windowOrNil { .window(windowOrNil) } else { .emptyWorkspace(workspace) }
    }
}

/// This object should be only passed around but never memorized
/// Alternative name: ResolvedFocus
struct LiveFocus: AeroAny, Equatable {
    let windowOrNil: Window?
    var workspace: Workspace

    @MainActor fileprivate var frozen: FrozenFocus {
        return FrozenFocus(
            windowId: windowOrNil?.windowId,
            workspaceName: workspace.name,
            monitorId_oneBased: workspace.workspaceMonitor.monitorId_oneBased ?? 0,
        )
    }
}

/// "old", "captured", "frozen in time" Focus
/// It's safe to keep a hard reference to this object.
/// Unlike in LiveFocus, information inside FrozenFocus isn't guaranteed to be self-consistent.
/// window - workspace - monitor relation could change since the moment object was created
private struct FrozenFocus: AeroAny, Equatable, Sendable {
    let windowId: UInt32?
    let workspaceName: String
    // monitorId is not part of the focus. We keep it here only for 'on-focused-monitor-changed' to work
    let monitorId_oneBased: Int

    @MainActor var live: LiveFocus { // Important: don't access focus.monitorId here. monitorId is not part of the focus. Always prefer workspace
        let window: Window? = windowId.flatMap { Window.get(byId: $0) }
        let workspace = Workspace.get(byName: workspaceName)

        let workspaceFocus = workspace.toLiveFocus()
        let windowFocus = window?.toLiveFocusOrNil() ?? workspaceFocus

        return workspaceFocus.workspace != windowFocus.workspace
            ? workspaceFocus // If window and workspace become separated prefer workspace
            : windowFocus
    }
}

@MainActor private var _focus: FrozenFocus = {
    let monitor = mainMonitor
    return FrozenFocus(windowId: nil, workspaceName: monitor.activeWorkspace.name, monitorId_oneBased: monitor.monitorId_oneBased ?? 0)
}()

/// Global focus.
/// Commands must be cautious about accessing this property directly. There are legitimate cases.
/// But, in general, commands must firstly check --window-id, --workspace, AIRLOCK_WINDOW_ID env and
/// AIRLOCK_WORKSPACE env before accessing the global focus.
@MainActor var focus: LiveFocus { _focus.live }

@MainActor func setFocus(to newFocus: LiveFocus) -> Bool {
    if _focus == newFocus.frozen { return true }
    let oldFocus = focus
    // Normalize mruWindow when focus away from a workspace
    if oldFocus.workspace != newFocus.workspace {
        oldFocus.windowOrNil?.markAsMostRecentChild()
    }

    _focus = newFocus.frozen
    let status = newFocus.workspace.workspaceMonitor.setActiveWorkspace(newFocus.workspace)

    newFocus.windowOrNil?.markAsMostRecentChild()
    return status
}
extension Window {
    @MainActor func focusWindow() -> Bool {
        if let focus = toLiveFocusOrNil() {
            return setFocus(to: focus)
        } else {
            //      and retry to focus the window. Otherwise, it's not possible to focus minimized/hidden windows
            return false
        }
    }

    @MainActor func toLiveFocusOrNil() -> LiveFocus? { visualWorkspace.map { LiveFocus(windowOrNil: self, workspace: $0) } }
}
extension Workspace {
    @MainActor func focusWorkspace() -> Bool { setFocus(to: toLiveFocus()) }

    func toLiveFocus() -> LiveFocus {
        //      while floating or macos unconventional windows might be presented
        if let wd = mostRecentWindowRecursive ?? anyLeafWindowRecursive {
            LiveFocus(windowOrNil: wd, workspace: self)
        } else {
            LiveFocus(windowOrNil: nil, workspace: self) // emptyWorkspace
        }
    }
}

@MainActor func updateFocusWorkspaceName(from oldName: String, to newName: String) {
    if _focus.workspaceName == oldName {
        _focus = FrozenFocus(windowId: _focus.windowId, workspaceName: newName, monitorId_oneBased: _focus.monitorId_oneBased)
    }
    if _lastKnownFocus.workspaceName == oldName {
        _lastKnownFocus = FrozenFocus(windowId: _lastKnownFocus.windowId, workspaceName: newName, monitorId_oneBased: _lastKnownFocus.monitorId_oneBased)
    }
    if _prevFocus?.workspaceName == oldName {
        _prevFocus = FrozenFocus(windowId: _prevFocus!.windowId, workspaceName: newName, monitorId_oneBased: _prevFocus!.monitorId_oneBased)
    }
    if _prevFocusedWorkspaceName == oldName {
        _prevFocusedWorkspaceName = newName
    }
}

@MainActor private var _lastKnownFocus: FrozenFocus = _focus

// Used by workspace-back-and-forth
@MainActor var _prevFocusedWorkspaceName: String? = nil {
    didSet {
        prevFocusedWorkspaceDate = .now
    }
}
@MainActor var prevFocusedWorkspaceDate: Date = .distantPast
@MainActor var prevFocusedWorkspace: Workspace? { _prevFocusedWorkspaceName.map { Workspace.get(byName: $0) } }

// Used by focus-back-and-forth
@MainActor private var _prevFocus: FrozenFocus? = nil
@MainActor var prevFocus: LiveFocus? { _prevFocus?.live.takeIf { $0 != focus } }

@MainActor func resetFocusStateForTests() {
    _prevFocus = nil
    _lastKnownFocus = _focus
}

@MainActor private var onFocusChangedRecursionGuard = false
// Should be called in refreshSession
@MainActor func checkOnFocusChangedCallbacks() {
    if refreshSessionEvent?.isStartup == true {
        return
    }
    let focus = focus
    let frozenFocus = focus.frozen
    var hasFocusChanged = false
    var hasFocusedWorkspaceChanged = false
    var hasFocusedMonitorChanged = false
    if frozenFocus != _lastKnownFocus {
        _prevFocus = _lastKnownFocus
        hasFocusChanged = true
    }
    if frozenFocus.workspaceName != _lastKnownFocus.workspaceName {
        _prevFocusedWorkspaceName = _lastKnownFocus.workspaceName
        hasFocusedWorkspaceChanged = true
    }
    if frozenFocus.monitorId_oneBased != _lastKnownFocus.monitorId_oneBased {
        hasFocusedMonitorChanged = true
    }
    _lastKnownFocus = frozenFocus

    if onFocusChangedRecursionGuard { return }
    onFocusChangedRecursionGuard = true
    defer { onFocusChangedRecursionGuard = false }
    if hasFocusChanged {
        maybeAutoFlash(prev: _prevFocus, curr: focus)
        onFocusChanged(focus)
    }
    if let _prevFocusedWorkspaceName, hasFocusedWorkspaceChanged {
        onWorkspaceChanged(_prevFocusedWorkspaceName, frozenFocus.workspaceName)
    }
    if hasFocusedMonitorChanged {
        onFocusedMonitorChanged(focus)
    }
}

@MainActor private func onFocusedMonitorChanged(_ focus: LiveFocus) {
    broadcastEvent(.focusedMonitorChanged(
        workspace: focus.workspace.name,
        monitorId_oneBased: focus.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
    ))
    if config.onFocusedMonitorChanged.isEmpty { return }
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    Task {
        try await runLightSession(.onFocusedMonitorChanged, token) {
            _ = try await config.onFocusedMonitorChanged.runCmdSeq(.defaultEnv.withFocus(focus), .emptyStdin)
        }
    }
}
@MainActor private func onFocusChanged(_ focus: LiveFocus) {
    broadcastEvent(.focusChanged(
        windowId: focus.windowOrNil?.windowId,
        workspace: focus.workspace.name,
    ))
    if config.onFocusChanged.isEmpty { return }
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    Task {
        try await runLightSession(.onFocusChanged, token) {
            _ = try await config.onFocusChanged.runCmdSeq(.defaultEnv.withFocus(focus), .emptyStdin)
        }
    }
}

@MainActor private func onWorkspaceChanged(_ oldWorkspace: String, _ newWorkspace: String) {
    broadcastEvent(.workspaceChanged(
        workspace: newWorkspace,
        prevWorkspace: oldWorkspace,
    ))
}

/// "Time since previous focus event" tracker used by the `idle` mode of
/// `[focus-flash]`. Updated unconditionally on every focus-change event (not
/// gated on whether a flash actually fired) — the semantic is "user has been
/// quiet for N seconds", not "we haven't flashed for N seconds".
///
/// Nil before the first focus event after launch. The first event treats
/// `secondsSincePrev` as 0 — Airlock just started, the user isn't "returning
/// from being idle", so `idle` mode shouldn't fire on the first event.
@MainActor private var _lastFocusChangeAt: Date? = nil

@MainActor private func maybeAutoFlash(prev: FrozenFocus?, curr: LiveFocus) {
    let cfg = config.focusFlash
    let now = Date()
    let secondsSincePrev: Double = _lastFocusChangeAt.map { now.timeIntervalSince($0) } ?? 0
    _lastFocusChangeAt = now

    guard cfg.enabled else { return }

    let prevWs = prev?.workspaceName
    let currWs = curr.workspace.name
    // FrozenFocus only stores the windowId; resolve the live Window to read its
    // app bundle id. If the previous window has been closed since the focus
    // event was captured, the lookup fails — we don't know what the previous
    // app was, so we treat it as "same as current". Trade-off: suppresses
    // false-positive cross-app flashes (close one Chrome window, land on the
    // next Chrome window) at the cost of also suppressing the legitimate
    // case (close the last Slack window, focus jumps to Chrome). False
    // positives are more annoying than missed flashes, so we accept the loss.
    let currApp = curr.windowOrNil?.app.rawAppBundleId
    let prevApp = prev?.windowId.flatMap { Window.get(byId: $0) }?.app.rawAppBundleId ?? currApp

    if shouldAutoFlash(
        mode: cfg.mode,
        prevWorkspace: prevWs,
        currWorkspace: currWs,
        prevAppId: prevApp,
        currAppId: currApp,
        secondsSincePrev: secondsSincePrev,
        idleThreshold: cfg.idleThresholdSeconds,
    ) {
        FocusFlashController.shared.flash(window: curr.windowOrNil)
    }
}
