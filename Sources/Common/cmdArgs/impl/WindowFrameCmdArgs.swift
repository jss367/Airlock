public struct WindowFrameCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .windowFrame,
        allowInConfig: true,
        help: window_frame_help_generated,
        flags: [
            "--window-id": optionalWindowIdFlag(),
            "--size": singleValueSubArgParser(\.sizePercent, "<percent>", parsePercent),
            "--width": singleValueSubArgParser(\.widthPercent, "<percent>", parsePercent),
            "--height": singleValueSubArgParser(\.heightPercent, "<percent>", parsePercent),
        ],
        posArgs: [newMandatoryPosArgParser(\.preset, parseWindowFramePreset, placeholder: Preset.unionLiteral)],
    )

    public var preset: Lateinit<Preset> = .uninitialized
    public var sizePercent: UInt? = nil
    public var widthPercent: UInt? = nil
    public var heightPercent: UInt? = nil

    public enum Preset: String, CaseIterable, Equatable, Sendable {
        case leftHalf = "left-half"
        case rightHalf = "right-half"
        case center
        case comfortable
    }
}

func parseWindowFrameCmdArgs(_ args: StrArrSlice) -> ParsedCmd<WindowFrameCmdArgs> {
    parseSpecificCmdArgs(WindowFrameCmdArgs(rawArgs: args), args)
        .filter("--size, --width, and --height are only compatible with comfortable") {
            ($0.sizePercent != nil || $0.widthPercent != nil || $0.heightPercent != nil).implies($0.preset.val == .comfortable)
        }
}

private func parsePercent(_ arg: String) -> UInt? {
    UInt(arg).flatMap { (1 ... 100).contains($0) ? $0 : nil }
}

private func parseWindowFramePreset(i: PosArgParserInput) -> ParsedCliArgs<WindowFrameCmdArgs.Preset> {
    .init(parseEnum(i.arg, WindowFrameCmdArgs.Preset.self), advanceBy: 1)
}
