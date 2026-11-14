public struct WorkspaceOverviewCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceOverview,
        allowInConfig: true,
        help: workspace_overview_help_generated,
        flags: [:],
        posArgs: [],
    )
}
