import AppKit
import Common

struct EnableCommand: Command {
    let args: EnableCmdArgs
    var requestedIntent: Int? = nil
    var beforeEnableEffects: @MainActor () async throws -> Void = {}
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let intent = requestedIntent ?? CommandInvocationIntent.order ?? beginEnableIntent()
        guard intent >= latestEnableIntent else { return true }
        // A trigger's reserved order becomes Enable intent only when it reaches this command.
        latestEnableIntent = intent
        return try await CommandInvocationIntent.$order.withValue(intent) {
            try await runWithIntent(intent, io)
        }
    }

    @MainActor
    private func runWithIntent(_ intent: Int, _ io: CmdIo) async throws -> Bool {
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

        if newState {
            for workspace in Workspace.all {
                for window in workspace.allLeafWindowsRecursive where window.isFloating {
                    guard intent == latestEnableIntent else { return true }
                    let size = try await window.getAxSize()
                    guard intent == latestEnableIntent else { return true }
                    try await beforeEnableEffects()
                    guard intent == latestEnableIntent else { return true }
                    window.lastFloatingSize = size ?? window.lastFloatingSize
                }
            }
            guard intent == latestEnableIntent else { return true }
            try await beforeEnableEffects()
            guard intent == latestEnableIntent else { return true }
            TrayMenuModel.shared.isEnabled = true
            registerQuickSwitcherHotkey()
            try await activateMode(mainModeId, beforeEffects: beforeEnableEffects)
            try await beforeEnableEffects()
        } else {
            TrayMenuModel.shared.isEnabled = false
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

@MainActor private var invocationSequence = 0
@MainActor private var latestEnableIntent = 0
private enum EnableIntentError: Error { case superseded }
@MainActor private func reserveInvocationOrder() -> Int {
    invocationSequence += 1
    return invocationSequence
}
@MainActor private func beginEnableIntent() -> Int {
    let order = reserveInvocationOrder()
    latestEnableIntent = order
    return order
}

/// Nested trigger-binding/config command sequences share the accepted invocation. New socket,
/// hotkey, or UI entrypoints still reserve their own intent before their session query.
private enum CommandInvocationIntent {
    @TaskLocal static var order: Int?
}

@MainActor
func validateInheritedEnableIntent() throws {
    if let intent = CommandInvocationIntent.order, intent < latestEnableIntent { throw CancellationError() }
}

/// Each accepted invocation owns a fresh token. Parsed/configured commands remain reusable;
/// only ephemeral copies passed to this invocation's body carry the reserved intent.
@MainActor
struct PreparedCommandSession {
    let commands: [any Command]
    private let intent: Int?

    init(_ commands: [any Command]) {
        // Triggers need an order before the query, since a live/reloaded binding may reach Enable.
        // They do not supersede actual Enable intent unless they execute an Enable command.
        let intent: Int? = if commands.contains(where: { $0 is EnableCommand }) { beginEnableIntent() }
        else if commands.contains(where: { $0 is TriggerBindingCommand }) { reserveInvocationOrder() }
        else { nil }
        self.intent = intent
        self.commands = commands.map { command in
            guard let enable = command as? EnableCommand else { return command }
            var prepared = enable
            prepared.requestedIntent = intent
            return prepared
        }
    }

    func run(_ env: CmdEnv, _ stdin: consuming CmdStdin) async throws -> CmdResult {
        let io = CmdIo(stdin: stdin)
        let success = try await CommandInvocationIntent.$order.withValue(intent) {
            try await commands.runCmdSeq(env, io, admissionCheck: validateAdmission)
        }
        return CmdResult(stdout: io.stdout, stderr: io.stderr, exitCode: success ? 0 : 1)
    }

    func validateAdmission() throws {
        if let intent, intent < latestEnableIntent { throw CancellationError() }
    }
}

/// Capture before queuing a feature action. Even a Pause followed by Resume supersedes that task.
@MainActor
func captureEnabledSessionAdmission() -> @MainActor () throws -> Void {
    let intent = latestEnableIntent
    return {
        guard TrayMenuModel.shared.isEnabled, intent == latestEnableIntent else { throw CancellationError() }
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
        guard intent == latestEnableIntent else { throw EnableIntentError.superseded }
    }
    let isResuming = !TrayMenuModel.shared.isEnabled && requestedState == .on
    var selectedCandidate: UiResumeFocusCandidate?
    let beforeEffects: @MainActor () async throws -> Void = {
        try validateIntent()
        try await selectedCandidate?.validateAfterSelection(validateIntent: validateIntent)
        try validateIntent()
    }
    markUserInitiatedFocusChange()
    // The paused model is stale. Ordinary sync could refocus it after grace expires during an AX query.
    do {
        try await CommandInvocationIntent.$order.withValue(intent) {
            try await runLightSession(.menuBarButton, .forceRun, syncFocusBeforeBody: !isResuming, admissionCheck: validateIntent, beforeEffects: beforeEffects) { () throws in
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
                        try validateIntent()
                        selectedCandidate = candidate
                        // A nested detection Enable belongs to this invocation. Its state change
                        // doesn't replace the validated selection; only a newer intent does.
                        _ = window.focusWindow()
                    }
                }
                try validateIntent()
                _ = try await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: requestedState), requestedIntent: intent, beforeEnableEffects: beforeEffects)
                    .run(.defaultEnv, .emptyStdin)
                try validateIntent()
            }
        }
    } catch EnableIntentError.superseded {
        // A later explicit request owns the state, including an off request that was already paused.
        return
    } catch is CancellationError where intent != latestEnableIntent {
        // Nested command dispatch detects the same supersession through its inherited token.
        return
    }
}
