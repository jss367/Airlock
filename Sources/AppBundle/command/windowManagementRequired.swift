import Common

/// While window management is off, Airlock doesn't hide anything, and each monitor's workspace simply holds the
/// windows that are on that monitor (see syncUnmanagedWindow). Moving a window to another workspace would be undone by
/// the next refresh, and showing another workspace on a monitor would pull every window on that monitor into it. So
/// the commands that need either fail instead of reporting a success that didn't happen.
@MainActor
func reportWindowManagementIsOff(_ io: CmdIo, _ action: String) -> Bool {
    io.err(windowManagementIsOffMessage(action))
}

private func windowManagementIsOffMessage(_ action: String) -> String {
    "\(action) requires window management. Turn on Window management in Settings, or set enable-window-management = true"
}

/// Focusing a workspace that some monitor already shows is fine without window management: nothing is moved.
/// Returns why the workspace can't be focused, or nil if it can.
@MainActor
private func workspaceFocusRefusal(_ workspace: Workspace) -> String? {
    config.enableWindowManagement || workspace.isVisible
        ? nil
        : windowManagementIsOffMessage("Switching to workspace '\(workspace.name)', which isn't shown on any monitor,")
}

@MainActor
func checkWorkspaceCanBeFocused(_ workspace: Workspace, _ io: CmdIo) -> Bool {
    workspaceFocusRefusal(workspace).map { io.err($0) } ?? true
}

/// For menus and panels, which have no CmdIo to report into: the same rule as the `workspace` command,
/// with the refusal shown as a message.
@MainActor
func focusWorkspaceFromUi(_ workspace: Workspace) {
    if let refusal = workspaceFocusRefusal(workspace) {
        MessageModel.shared.message = Message(description: "Can't Switch Workspace", body: refusal)
    } else {
        _ = workspace.focusWorkspace()
    }
}


/// Window selection from Quick Switcher and Mission Control shares the workspace visibility rule.
@MainActor
func focusWindowFromUi(_ window: Window) {
    guard let workspace = window.visualWorkspace else { return }
    if let refusal = workspaceFocusRefusal(workspace) {
        MessageModel.shared.message = Message(description: "Can't Switch Workspace", body: refusal)
    } else {
        _ = window.focusWindow()
    }
}
