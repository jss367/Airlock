import AppKit
import Common

struct EnableCommand: Command {
    let args: EnableCmdArgs
    var uiIntent: Int? = nil
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let intent = uiIntent ?? beginEnableIntent()
        guard intent == enableIntentGeneration else { return true }
        let prevState = TrayMenuModel.shared.isEnabled
        let newState: Bool = switch args.targetState.val {
            case .on: true
            case .off: false
            case .toggle: !TrayMenuModel.shared.isEnabled
        }
        if !newState { dismissAppLauncherForPause() }
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
                    guard intent == enableIntentGeneration else { return true }
                    let size = try await window.getAxSize()
                    guard intent == enableIntentGeneration else { return true }
                    window.lastFloatingSize = size ?? window.lastFloatingSize
                }
            }
            guard intent == enableIntentGeneration else { return true }
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

@MainActor private var enableIntentGeneration = 0
private enum EnableIntentError: Error { case superseded }
@MainActor private func beginEnableIntent() -> Int {
    enableIntentGeneration += 1
    return enableIntentGeneration
}

/// Capture before queuing a feature action. Even a Pause followed by Resume supersedes that task.
@MainActor
func captureEnabledSessionAdmission() -> @MainActor () throws -> Void {
    let intent = enableIntentGeneration
    return {
        guard TrayMenuModel.shared.isEnabled, intent == enableIntentGeneration else { throw CancellationError() }
    }
}

/// Pause or resume from Airlock's own UI. Nothing records focus while paused, so the session's
/// focus sync would treat the window the user worked in meanwhile as a steal, push focus back to
/// the pre-pause window, and the resumed layout would hide the user's window. Clicks on Airlock's
/// own menu and windows never reach the global mouse monitor, so mark the intent here, as the
/// socket server does before `airlock enable`
@MainActor
func runEnableCommandFromUi(_ targetState: EnableCmdArgs.State) async throws {
    // A toggle describes the user's intent now, not the running state after an awaited query.
    let requestedState: EnableCmdArgs.State = targetState == .toggle
        ? (TrayMenuModel.shared.isEnabled ? .off : .on)
        : targetState
    let intent = beginEnableIntent()
    let validateIntent: @MainActor () throws -> Void = {
        guard intent == enableIntentGeneration else { throw EnableIntentError.superseded }
    }
    let isResuming = !TrayMenuModel.shared.isEnabled && requestedState == .on
    markUserInitiatedFocusChange()
    // The paused model is stale. Ordinary sync could refocus it after grace expires during an AX query.
    do {
        try await runLightSession(.menuBarButton, .forceRun, syncFocusBeforeBody: !isResuming) { () throws in
            try validateIntent()
            if isResuming && !TrayMenuModel.shared.isEnabled {
                let candidate = try await uiResumeFocus.candidateToResume(nativeFocus: nativeFocusCandidateForUiResume)
                try validateIntent()
                // Another UI action can finish resuming while the query is suspended.
                if !TrayMenuModel.shared.isEnabled, let candidate {
                    // Registration and configured detection callbacks begin only after a stable selection.
                    guard let window = try await candidate.resolveAfterSelection(validateIntent: validateIntent), window.isBound else {
                        throw UiResumeFocusError.selectedWindowUnavailable
                    }
                    if !TrayMenuModel.shared.isEnabled { _ = window.focusWindow() }
                }
            }
            try validateIntent()
            _ = try await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: requestedState), uiIntent: intent)
                .run(.defaultEnv, .emptyStdin)
            try validateIntent()
        }
    } catch EnableIntentError.superseded {
        // A later explicit request owns the state, including an off request that was already paused.
        return
    }
}
