import AppKit
import Common

struct FlashFocusCommand: Command {
    let args: FlashFocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        FocusFlashController.shared.flash(window: target.windowOrNil)
        return true
    }
}
