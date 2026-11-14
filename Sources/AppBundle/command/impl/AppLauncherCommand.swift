import AppKit
import Common

struct AppLauncherCommand: Command {
    let args: AppLauncherCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard sessionCoordinator.isEnabled else { return false }
        // The launcher is the Quick Switcher panel, narrowed down to installed apps
        showQuickSwitcher(scope: .apps)
        return true
    }
}
