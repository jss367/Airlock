import AppKit
import Common

struct EnableCommand: Command {
    let args: EnableCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let prevState = TrayMenuModel.shared.isEnabled
        let newState: Bool = switch args.targetState.val {
            case .on: true
            case .off: false
            case .toggle: !TrayMenuModel.shared.isEnabled
        }
        if newState == prevState {
            if !args.failIfNoop {
                io.out((newState ? "Already enabled" : "Already disabled") +
                    ". Tip: use --fail-if-noop to exit with non-zero code")
            }
            return !args.failIfNoop
        }

        TrayMenuModel.shared.isEnabled = newState
        registerQuickSwitcherHotkey()
        if newState {
            for workspace in Workspace.all {
                for window in workspace.allLeafWindowsRecursive where window.isFloating {
                    window.lastFloatingSize = try await window.getAxSize() ?? window.lastFloatingSize
                }
            }
            try await activateMode(mainModeId)
        } else {
            // Before activateMode, whose on-mode-changed callbacks may be slow or throw.
            // The panel activated Airlock, so hand focus back to the real window
            if isQuickSwitcherOpen { dismissQuickSwitcher() }
            if isMissionControlOpen { dismissMissionControl() }
            try await activateMode(nil)
        }
        return true
    }
}

/// Pause or resume from Airlock's own UI. Nothing records focus while paused, so the session's
/// focus sync would treat the window the user worked in meanwhile as a steal, push focus back to
/// the pre-pause window, and the resumed layout would hide the user's window. Clicks on Airlock's
/// own menu and windows never reach the global mouse monitor, so mark the intent here, as the
/// socket server does before `airlock enable`
@MainActor
func runEnableCommandFromUi(_ targetState: EnableCmdArgs.State) async throws {
    let isResuming = !TrayMenuModel.shared.isEnabled && targetState != .off
    markUserInitiatedFocusChange()
    // The paused model is stale. Ordinary sync could refocus it after grace expires during an AX query.
    try await runLightSession(.menuBarButton, .forceRun, syncFocusBeforeBody: !isResuming) { () throws in
        if isResuming && !TrayMenuModel.shared.isEnabled {
            let candidate = try await uiResumeFocus.candidateToResume(nativeFocus: nativeFocusCandidateForUiResume)
            // Another UI action can finish resuming while the query is suspended.
            if !TrayMenuModel.shared.isEnabled, let candidate {
                // Registration and configured detection callbacks begin only after a stable selection.
                guard let window = try await candidate.resolveAfterSelection(), window.isBound else {
                    throw UiResumeFocusError.selectedWindowUnavailable
                }
                if !TrayMenuModel.shared.isEnabled { _ = window.focusWindow() }
            }
        }
        _ = try await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: targetState))
            .run(.defaultEnv, .emptyStdin)
    }
}
