import Common

/// While window management is off, Airlock doesn't hide anything, and each monitor's workspace simply holds the
/// windows that are on that monitor (see syncUnmanagedWindow). Moving a window to another workspace would be undone by
/// the next refresh, and showing another workspace on a monitor would pull every window on that monitor into it. So
/// the commands that need either fail instead of reporting a success that didn't happen.
@MainActor
func reportWindowManagementIsOff(_ io: CmdIo, _ action: String) -> Bool {
    io.err("\(action) requires window management. Turn on Window management in Feature Settings, or set enable-window-management = true")
}

/// Focusing a workspace that some monitor already shows is fine without window management: nothing is moved.
@MainActor
func checkWorkspaceCanBeFocused(_ workspace: Workspace, _ io: CmdIo) -> Bool {
    config.enableWindowManagement || workspace.isVisible ||
        reportWindowManagementIsOff(io, "Switching to workspace '\(workspace.name)', which isn't shown on any monitor,")
}
