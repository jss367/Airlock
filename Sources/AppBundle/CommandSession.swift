import Common

/// Nested trigger-binding/config command sequences share the accepted invocation. New socket,
/// hotkey, or UI entrypoints still reserve their own intent before their session query.
enum CommandInvocationIntent {
    @TaskLocal static var order: Int?
    @TaskLocal static var resumeWindowAdmission: ResumeWindowAdmission?
}

/// A moved candidate must be re-adopted before a nested mode session reads modeled focus.
struct ResumeWindowAdmission: Sendable {
    let order: Int
    let validate: @MainActor () async throws -> Void
    let adopt: @MainActor () async throws -> Void
}

@MainActor
func adoptResumeWindowBeforeModeCallbacks() async throws {
    guard let admission = CommandInvocationIntent.resumeWindowAdmission,
          admission.order == CommandInvocationIntent.order else { return }
    try await admission.adopt()
}

@MainActor
func validateResumeWindowBeforeModeEffects() async throws {
    guard let admission = CommandInvocationIntent.resumeWindowAdmission,
          admission.order == CommandInvocationIntent.order else { return }
    try await admission.validate()
}

@MainActor
func validateInheritedEnableIntent() throws {
    if let intent = CommandInvocationIntent.order { try sessionCoordinator.validateInvocation(intent) }
}

/// Each accepted invocation owns a fresh token. Parsed/configured commands remain reusable;
/// only ephemeral copies passed to this invocation's body carry the reserved intent.
@MainActor
struct PreparedCommandSession {
    let commands: [any Command]
    let admission: RunSessionGuard

    init(_ commands: [any Command]) {
        // Any command can reach Enable through a configured callback or a live binding.
        // Reserving an order alone does not supersede an earlier pending Enable request.
        let intent = commands.contains(where: { $0 is EnableCommand })
            ? sessionCoordinator.beginEnableIntent()
            : sessionCoordinator.reserveInvocationOrder()
        admission = .command(intent: intent)
        self.commands = commands.map { command in
            guard let enable = command as? EnableCommand else { return command }
            var prepared = enable
            prepared.requestedIntent = intent
            return prepared
        }
    }

    func run(_ env: CmdEnv, _ stdin: consuming CmdStdin) async throws -> CmdResult {
        let io = CmdIo(stdin: stdin)
        let success = try await CommandInvocationIntent.$order.withValue(admission.invocationOrder) {
            try await commands.runCmdSeq(env, io, admissionCheck: validateAdmission)
        }
        return CmdResult(stdout: io.stdout, stderr: io.stderr, exitCode: success ? 0 : 1)
    }

    func validateAdmission() throws {
        try admission.validateAdmission()
    }
}
