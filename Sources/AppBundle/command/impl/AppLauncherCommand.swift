import AppKit
import Common

struct AppLauncherCommand: Command {
    let args: AppLauncherCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard TrayMenuModel.shared.isEnabled else { return false }
        AppLauncherPanel.shared.show()
        return true
    }
}
