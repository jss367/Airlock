public struct FlashFocusCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .flashFocus,
        allowInConfig: true,
        help: flash_focus_help_generated,
        flags: [:],
        posArgs: [],
    )
}
