import AppKit
import Common

struct WorkspaceBackAndForthCommand: Command {
    let args: WorkspaceBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let prevFocusedWorkspace else { return false }
        guard checkWorkspaceCanBeFocused(prevFocusedWorkspace, io) else { return false }
        return prevFocusedWorkspace.focusWorkspace()
    }
}
