public struct MissionControlCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .missionControl,
        allowInConfig: true,
        help: mission_control_help_generated,
        flags: [:],
        posArgs: [],
    )
}
