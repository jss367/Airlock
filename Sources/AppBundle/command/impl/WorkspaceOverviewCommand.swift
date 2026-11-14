import AppKit
import Common

struct WorkspaceOverviewCommand: Command {
    let args: WorkspaceOverviewCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        toggleMissionControl()
        return true
    }
}
