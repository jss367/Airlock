import AppKit
import Common

struct FlashFocusCommand: Command {
    let args: FlashFocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let target = args.resolveTargetOrReportError(env, io)
        FocusFlashController.shared.flash(window: target?.windowOrNil)
        return true
    }
}
