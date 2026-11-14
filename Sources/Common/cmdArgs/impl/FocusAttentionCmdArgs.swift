public struct FocusAttentionCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .focusAttention,
        allowInConfig: true,
        help: focus_attention_help_generated,
        flags: [:],
        posArgs: [],
    )
}
