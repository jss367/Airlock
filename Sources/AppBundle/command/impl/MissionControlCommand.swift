import AppKit
import Common

struct MissionControlCommand: Command {
    let args: MissionControlCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        toggleMissionControl()
        return true
    }
}
