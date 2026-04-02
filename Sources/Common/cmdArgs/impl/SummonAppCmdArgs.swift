public struct SummonAppCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .summonApp,
        allowInConfig: true,
        help: summon_app_help_generated,
        flags: [
            "--new-window": trueBoolFlag(\.newWindow),
        ],
        posArgs: [newMandatoryPosArgParser(\.appName, consumeStrCliArg, placeholder: "<app-name>")],
    )

    public var appName: Lateinit<String> = .uninitialized
    public var newWindow: Bool = false
}
