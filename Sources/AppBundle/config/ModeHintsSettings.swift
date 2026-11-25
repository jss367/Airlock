import Common
import TOMLKit

/// The `[mode-hints]` table: the panel that lists a binding mode's keys while the mode is active.
struct ModeHintsSettings: ConvenienceCopyable, Equatable, Sendable {
    var enabled: Bool = true

    static let `default` = ModeHintsSettings()
}

private let modeHintsParser: [String: any ParserProtocol<ModeHintsSettings>] = [
    "enabled": Parser(\.enabled, parseBool),
]

func parseModeHints(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> ModeHintsSettings {
    parseTable(raw, .default, modeHintsParser, backtrace, &errors)
}
