public struct AppLauncherCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .appLauncher,
        allowInConfig: true,
        help: app_launcher_help_generated,
        flags: [:],
        posArgs: [],
    )
}
