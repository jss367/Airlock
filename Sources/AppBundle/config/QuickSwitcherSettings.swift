import AppKit
import Common
import HotKey
import TOMLKit

struct QuickSwitcherSettings: ConvenienceCopyable, Equatable, Sendable {
    var enabled: Bool = true
    var binding: String = "option-space"

    static let `default` = QuickSwitcherSettings()
}

private let quickSwitcherParser: [String: any ParserProtocol<QuickSwitcherSettings>] = [
    "enabled": Parser(\.enabled, parseBool),
    "binding": Parser(\.binding, parseString),
]

func parseQuickSwitcher(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> QuickSwitcherSettings {
    parseTable(raw, .default, quickSwitcherParser, backtrace, &errors)
}
