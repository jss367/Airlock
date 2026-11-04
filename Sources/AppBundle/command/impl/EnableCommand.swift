import AppKit
import Common

struct EnableCommand: Command {
    let args: EnableCmdArgs
    var requestedIntent: Int? = nil
    var beforeEnableEffects: @MainActor () async throws -> Void = {}
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let intent = requestedIntent ?? CommandInvocationIntent.order ?? sessionCoordinator.beginEnableIntent()
        // A trigger's reserved order becomes Enable intent only when it reaches this command.
        guard sessionCoordinator.acceptEnableIntent(intent) else { return true }
        return try await CommandInvocationIntent.$order.withValue(intent) {
            try await runWithIntent(intent, io)
        }
    }

    @MainActor
    private func runWithIntent(_ intent: Int, _ io: CmdIo) async throws -> Bool {
        let prevState = sessionCoordinator.isEnabled
        let newState: Bool = switch args.targetState.val {
            case .on: true
            case .off: false
            case .toggle: !sessionCoordinator.isEnabled
        }
        if !newState { dismissAppLauncherForPause() }
        if newState == prevState {
            if !args.failIfNoop {
                io.out((newState ? "Already enabled" : "Already disabled") +
                    ". Tip: use --fail-if-noop to exit with non-zero code")
            }
            return !args.failIfNoop
        }

        if newState {
            for workspace in Workspace.all {
                for window in workspace.allLeafWindowsRecursive where window.isFloating {
                    guard sessionCoordinator.isCurrent(intent) else { return true }
                    let size = try await window.getAxSize()
                    guard sessionCoordinator.isCurrent(intent) else { return true }
                    try await beforeEnableEffects()
                    guard sessionCoordinator.isCurrent(intent) else { return true }
                    window.lastFloatingSize = size ?? window.lastFloatingSize
                }
            }
            guard sessionCoordinator.isCurrent(intent) else { return true }
            try await beforeEnableEffects()
            guard sessionCoordinator.isCurrent(intent) else { return true }
            sessionCoordinator.setEnabled(true)
            registerQuickSwitcherHotkey()
            var callbacksAdmitted = false
            do {
                try await activateMode(mainModeId, beforeEffects: beforeEnableEffects, onCallbacksAdmitted: { callbacksAdmitted = true })
                try await beforeEnableEffects()
            } catch {
                if error is UiResumeFocusError, !callbacksAdmitted, sessionCoordinator.isCurrent(intent) {
                    // The mode preflight rejected this owned resume before callback effects began.
                    // Preserve detection effects (e.g. moves), but restore paused state/hotkeys.
                    sessionCoordinator.setEnabled(false)
                    registerQuickSwitcherHotkey()
                    try await activateMode(nil, beforeStateChange: { sessionCoordinator.isCurrent(intent) })
                }
                throw error
            }
        } else {
            sessionCoordinator.setEnabled(false)
            registerQuickSwitcherHotkey()
            // Before activateMode, whose on-mode-changed callbacks may be slow or throw.
            // The panel activated Airlock, so hand focus back to the real window
            if isQuickSwitcherOpen { dismissQuickSwitcher() }
            if isMissionControlOpen { dismissMissionControl() }
            try await activateMode(nil)
        }
        return true
    }
}

private enum EnableIntentError: Error { case superseded }

/// Pause or resume from Airlock's own UI. Nothing records focus while paused, so the session's
/// focus sync would treat the window the user worked in meanwhile as a steal, push focus back to
/// the pre-pause window, and the resumed layout would hide the user's window. Clicks on Airlock's
/// own menu and windows never reach the global mouse monitor, so mark the intent here, as the
/// socket server does before `airlock enable`
@MainActor
func runEnableCommandFromUi(_ targetState: EnableCmdArgs.State) async throws {
    // A toggle describes the user's intent now, not the running state after an awaited query.
    let requestedState: EnableCmdArgs.State = targetState == .toggle
        ? (sessionCoordinator.isEnabled ? .off : .on)
        : targetState
    let isResuming = !sessionCoordinator.isEnabled && requestedState == .on
    try await runEnableCommandsWithFocusAdoption(
        [EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: requestedState))], event: .menuBarButton,
        syncFocusBeforeBody: !isResuming,
    )
}

/// Resume from a paused model without treating its old focus as authoritative. A sequence shares
/// one intent, so a later explicit invocation also cancels its remaining enable commands.
@MainActor
func runEnableCommandsWithFocusAdoption(_ commands: [EnableCommand], event: RefreshSessionEvent, syncFocusBeforeBody: Bool) async throws {
    let wasEnabled = sessionCoordinator.isEnabled
    let intent = sessionCoordinator.beginEnableIntent()
    let validateIntent: @MainActor @Sendable () throws -> Void = {
        guard sessionCoordinator.isCurrent(intent) else { throw EnableIntentError.superseded }
    }
    let isResuming = !wasEnabled && commands.contains { $0.args.targetState.val != .off }
    var selectedCandidate: UiResumeFocusCandidate?
    var adoptedBeforeCallbacks = false
    let beforeEffects: @MainActor () async throws -> Void = {
        try validateIntent()
        try await selectedCandidate?.validateAfterSelection(validateIntent: validateIntent)
        try validateIntent()
    }
    markUserInitiatedFocusChange()
    // The paused model is stale. Ordinary sync could refocus it after grace expires during an AX query.
    do {
        try await CommandInvocationIntent.$order.withValue(intent) {
            try await runLightSession(event, .command(intent: intent, check: validateIntent), syncFocusBeforeBody: syncFocusBeforeBody, beforeEffects: beforeEffects) { () throws in
                try validateIntent()
                if isResuming && !sessionCoordinator.isEnabled {
                    let candidate = try await uiResumeFocus.candidateToResume(nativeFocus: nativeFocusCandidateForUiResume)
                    try validateIntent()
                    // Another UI action can finish resuming while the query is suspended.
                    if !sessionCoordinator.isEnabled, let candidate {
                        // Registration and configured detection callbacks begin only after a stable selection.
                        var resolvingWindow: Window?
                        var resolvedWindow: Window?
                        let admission = ResumeWindowAdmission(order: intent, validate: {
                            guard let window = resolvingWindow else { return }
                            try await candidate.validateAfterSelection(validateIntent: validateIntent)
                            guard window.isBound else { throw UiResumeFocusError.selectedWindowUnavailable }
                        }, adopt: {
                            guard let window = resolvingWindow else { return }
                            try await candidate.validateAfterSelection(validateIntent: validateIntent)
                            guard window.isBound else { throw UiResumeFocusError.selectedWindowUnavailable }
                            try validateIntent()
                            selectedCandidate = candidate
                            _ = window.focusWindow()
                        })
                        try await CommandInvocationIntent.$resumeWindowAdmission.withValue(admission) {
                            resolvedWindow = try await candidate.resolveAfterSelection(validateIntent: validateIntent, beforeWindowCallbacks: { window in
                                try validateIntent()
                                guard window.isBound else { throw UiResumeFocusError.selectedWindowUnavailable }
                                resolvingWindow = window
                                if !adoptedBeforeCallbacks {
                                    selectedCandidate = candidate
                                    _ = window.focusWindow()
                                    adoptedBeforeCallbacks = true
                                }
                            })
                        }
                        guard let window = resolvedWindow, window.isBound else {
                            throw UiResumeFocusError.selectedWindowUnavailable
                        }
                        try validateIntent()
                        selectedCandidate = candidate
                        // A nested detection Enable belongs to this invocation. Its state change
                        // doesn't replace the validated selection; only a newer intent does.
                        _ = window.focusWindow()
                    }
                }
                try validateIntent()
                let preparedCommands: [any Command] = commands.map { command in
                    var prepared = command
                    prepared.requestedIntent = intent
                    let originalBeforeEffects = command.beforeEnableEffects
                    prepared.beforeEnableEffects = {
                        try await beforeEffects()
                        try await originalBeforeEffects()
                        try await beforeEffects()
                    }
                    return prepared
                }
                _ = try await preparedCommands.runCmdSeq(.defaultEnv, .emptyStdin)
                try validateIntent()
            }
        }
    } catch EnableIntentError.superseded {
        // A later explicit request owns the state, including an off request that was already paused.
        return
    } catch is CancellationError where !sessionCoordinator.isCurrent(intent) {
        // Nested command dispatch detects the same supersession through its inherited token.
        return
    }
}
