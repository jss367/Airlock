import AppKit
import Common
import Network

func startUnixSocketServer() {
    try? FileManager.default.removeItem(atPath: socketPath)
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .unix(path: socketPath)
    let listener = Result { try NWListener(using: params) }.getOrDie()
    listener.newConnectionHandler = { connection in
        Task {
            defer { connection.cancel() }
            connection.start(queue: .global())
            await newConnection(connection)
        }
    }
    listener.start(queue: .global())
}

func toggleReleaseServerIfDebug(_ state: EnableCmdArgs.State) async {
    if serverArgs.isReadOnly { return }
    if !isDebug { return }
    let socketFile = "/tmp/\(stableAirlockAppId)-\(unixUserName).sock"
    let connection = NWConnection(to: NWEndpoint.unix(path: socketFile), using: .tcp)
    defer { connection.cancel() }
    if await connection.startBlocking().error != nil { // Can't connect, Airlock.app is not running
        return
    }

    let req = ClientRequest(args: ["enable", state.rawValue], stdin: "", windowId: nil, workspace: nil)
    if await connection.writeAtomic(req).error != nil { return }
    _ = await connection.readNonAtomic()
}

private let serverVersionAndHash = "\(airlockAppVersion) \(gitHash)"

private func newConnection(_ connection: NWConnection) async {
    func answerToClient(exitCode: Int32, stdout: String = "", stderr: String = "") async {
        let ans = ServerAnswer(exitCode: exitCode, stdout: stdout, stderr: stderr, serverVersionAndHash: serverVersionAndHash)
        await answerToClient(ans)
    }
    func answerToClient(_ ans: ServerAnswer) async {
        // A rejected/failed response must close the connection so the client doesn't wait forever.
        if await connection.writeAtomic(ans).error != nil { connection.cancel() }
    }
    while true {
        let rawRequest: Data
        switch await connection.readNonAtomic() {
            case .success(let _rawRequest): rawRequest = _rawRequest
            case .failure(let error):
                await answerToClient(exitCode: 1, stderr: "Error: \(error)")
                return
        }
        let request: ClientRequest
        switch ClientRequest.decodeJson(rawRequest) {
            case .success(let _request): request = _request
            case .failure(let error):
                await answerToClient(
                    exitCode: 1,
                    stderr: """
                        Can't parse request '\(String(describing: String(data: rawRequest, encoding: .utf8)).singleQuoted)'.
                        Error: \(error)
                        """,
                )
                continue
        }
        // Handle subscribe before parseCommand (subscribe doesn't have a Command impl)
        if request.args.first == "subscribe" {
            switch parseSubscribeCmdArgs(request.args.slice(1...).orDie()) {
                case .cmd(let subscribeArgs): await handleSubscribeAndWaitTillError(connection, subscribeArgs)
                case .help(let help): await answerToClient(exitCode: 0, stdout: help)
                case .failure(let err): await answerToClient(exitCode: 1, stderr: err)
            }
            continue
        }
        let (command, help, err) = parseCommand(request.args).unwrap()
        guard let token: RunSessionGuard = await .isServerEnabled(orIsEnableCommand: command) else {
            await answerToClient(
                exitCode: 1,
                stderr: "\(airlockAppName) server is disabled and doesn't accept commands. " +
                    "You can use 'airlock enable on' to enable the server",
            )
            continue
        }
        if let help {
            await answerToClient(exitCode: 0, stdout: help)
            continue
        }
        if let err {
            await answerToClient(exitCode: 1, stderr: err)
            continue
        }
        if command?.isExec == true {
            await answerToClient(exitCode: 1, stderr: "exec-and-forget is prohibited in CLI")
            continue
        }
        if let command {
            let _answer: Result<ServerAnswer, Error> = await Result {
                try await runSocketCommandSession(command, request: request, token: token)
            }
            var answer = _answer.getOrNil() ??
                ServerAnswer(
                    exitCode: 1,
                    stderr: "Fail to await main thread. \(_answer.failureOrNil?.localizedDescription ?? "")",
                    serverVersionAndHash: serverVersionAndHash,
                )
            if request.windowId == nil || request.workspace == nil {
                answer.stderr += "\n\nAirlock client has sent incomplete JSON request. 'windowId' or/and 'workspace' fields are missing. Please forward your AIRLOCK_WINDOW_ID and AIRLOCK_WORKSPACE environment variables to these JSON fields. If the appropriate environment variables are empty, pass explict 'null' in the JSON."
            }
            await answerToClient(answer)
            continue
        }
        die("Unreachable")
    }
}

/// Parsed request dispatch, kept separate from transport so the full session prelude is testable.
@MainActor
func runSocketCommandSession(_ command: any Command, request: ClientRequest, token: RunSessionGuard) async throws -> ServerAnswer {
    let prepared = PreparedCommandSession([command])
    if command.info.kind.mayChangeFocus { markUserInitiatedFocusChange() }
    return try await runLightSession(.socketServer(command.args), token, admissionCheck: prepared.validateAdmission) {
        let env = CmdEnv(windowId: request.windowId.flatMap { $0 }, workspaceName: request.workspace.flatMap { $0 })
        let result = try await prepared.commands.runCmdSeq(env, CmdStdin(request.stdin), admissionCheck: prepared.validateAdmission)
        return ServerAnswer(exitCode: result.exitCode, stdout: result.stdout.joined(separator: "\n"), stderr: result.stderr.joined(separator: "\n"), serverVersionAndHash: serverVersionAndHash)
    }
}
