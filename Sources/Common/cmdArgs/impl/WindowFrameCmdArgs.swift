public struct WindowFrameCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .windowFrame,
        allowInConfig: true,
        help: window_frame_help_generated,
        flags: [
            "--window-id": optionalWindowIdFlag(),
        ],
        posArgs: [newMandatoryPosArgParser(\.preset, parseWindowFramePreset, placeholder: Preset.unionLiteral)],
    )

    public var preset: Lateinit<Preset> = .uninitialized

    public enum Preset: String, CaseIterable, Equatable, Sendable {
        case leftHalf = "left-half"
        case rightHalf = "right-half"
        case center
        case comfortable
    }
}

private func parseWindowFramePreset(i: PosArgParserInput) -> ParsedCliArgs<WindowFrameCmdArgs.Preset> {
    .init(parseEnum(i.arg, WindowFrameCmdArgs.Preset.self), advanceBy: 1)
}
