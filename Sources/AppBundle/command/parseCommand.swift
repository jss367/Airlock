import Common
import TOMLKit

/// The shell consumes everything after the command name, including quotes and separators.
func execAndForgetScript(in raw: String) -> Substring? {
    let command = raw.drop(while: \.isWhitespace)
    let name = command.prefix(while: { !$0.isWhitespace })
    guard name == CmdKind.execAndForget.rawValue else { return nil }
    return command[name.endIndex...]
}

func parseCommand(_ raw: String) -> ParsedCmd<any Command> {
    if let script = execAndForgetScript(in: raw) {
        return .cmd(ExecAndForgetCommand(args: ExecAndForgetCmdArgs(bashScript: String(script))))
    }
    return switch raw.splitArgs() {
        case .success(let args): parseCommand(args)
        case .failure(let fail): .failure(fail)
    }
}

func parseCommand(_ args: [String]) -> ParsedCmd<any Command> {
    parseCmdArgs(args.slice)
        // subscribe has no Command impl. The server handles it before calling parseCommand
        .filterNot("Command 'subscribe' can only be run from the CLI") { $0.kind == .subscribe }
        .map { $0.toCommand() }
}

func expectedActualTypeError(expected: TOMLType, actual: TOMLType) -> String {
    "Expected type is '\(expected)'. But actual type is '\(actual)'"
}

func expectedActualTypeError(expected: [TOMLType], actual: TOMLType) -> String {
    if let single = expected.singleOrNil() {
        return expectedActualTypeError(expected: single, actual: actual)
    } else {
        return "Expected types are \(expected.map { "'\($0.description)'" }.joined(separator: " or ")). But actual type is '\(actual)'"
    }
}
