import AppKit
import Common
import Foundation
import HotKey
import TOMLKit

enum ConfigWriterError: LocalizedError {
    case ambiguousConfig([URL])
    case writeError(String)
    case unrepresentableAppName(String)
    case inlineTable(String)
    case invalidConfig(String)
    case unsupportedEdit(String)

    var errorDescription: String? {
        switch self {
            case .ambiguousConfig(let urls):
                return "Multiple config files found: \(urls.map(\.path).joined(separator: ", "))"
            case .writeError(let msg):
                return "Failed to write config: \(msg)"
            case .unrepresentableAppName(let name):
                return "Cannot bind '\(name)': app names containing both ' and \" are not supported"
            case .inlineTable(let table):
                return "'\(table)' is written as an inline table. Edit it in the config file instead"
            case .invalidConfig(let msg):
                return "The config file has a syntax error. Fix it before changing settings here: \(msg)"
            case .unsupportedEdit(let path):
                return "Can't safely set '\(path)' in this config file. Edit it in the config file instead"
        }
    }
}

/// `key` is the physical key as the visualizer names it (qwerty notation). `keyMapping` is the
/// active `[key-mapping]`, which the config parser uses to turn the written key name back into a key code.
func addBinding(key: String, appName: String, modifierPrefix: NSEvent.ModifierFlags, keyMapping: [String: Key]) throws {
    guard canRepresentAppName(appName) else { throw ConfigWriterError.unrepresentableAppName(appName) }
    let file = try configFileForEditing(contentIfMissing: ["[mode.main.binding]", ""])
    let content = try addBindingToLines(file.lines, key: key, appName: appName, modifierPrefix: modifierPrefix, keyMapping: keyMapping)
    try writeConfigLines(content, to: file.url, separator: file.separator)
}

/// Pure line-manipulation logic for adding a binding, separated from file I/O for testability.
func addBindingToLines(
    _ lines: [String],
    key: String,
    appName: String,
    modifierPrefix: NSEvent.ModifierFlags,
    keyMapping: [String: Key] = keyNotationToKeyCode,
) throws -> [String] {
    var content = lines

    let physicalKey = keyNotationToKeyCode[key]
    let configKey = physicalKey.flatMap { configKeyNotation(for: $0, in: keyMapping) } ?? key
    let bindingKey = "\(modifierPrefix.toString())-\(configKey)"
    // A mapped key name can need quoting, e.g. one with a dot would otherwise read as a dotted key
    let bindingLine = "    \(tomlKey(bindingKey)) = \(summonAppTomlValue(appName: appName))"

    // Find [mode.main.binding] section
    if let sectionIndex = content.firstIndex(where: { tomlTableHeader($0) == "mode.main.binding" }) {
        // Remove existing binding for this key+modifier (matching by parsed modifiers, not string)
        let sectionEnd = tomlSectionEnd(content, sectionStart: sectionIndex)
        content = removeMatchingBindingLines(content, sectionStart: sectionIndex, sectionEnd: sectionEnd, key: key, modifiers: modifierPrefix, keyMapping: keyMapping)

        // Insert before the next section header or at end of file
        content.insert(bindingLine, at: tomlSectionEnd(content, sectionStart: sectionIndex))
    } else {
        // No [mode.main.binding] section exists, append it
        if !content.isEmpty && !content.last!.isEmpty {
            content.append("")
        }
        content.append("[mode.main.binding]")
        content.append(bindingLine)
    }

    let bindingTable = ["mode", "main", "binding"]
    try verifyTomlEdit(from: lines, to: content, path: bindingTable + [bindingKey]) { entries in
        entries.values = entries.values.filter { path, _ in
            !(path.count > bindingTable.count && path.starts(with: bindingTable) &&
                bindingKeyMatches(path[bindingTable.count], key: key, modifiers: modifierPrefix, keyMapping: keyMapping))
        }
        entries.set(bindingTable + [bindingKey], .string(summonAppCommand(appName: appName)))
    }
    return content
}

/// `splitArgs()` has no escape sequences, so an app name containing both quote characters
/// cannot be written as a single argument.
func canRepresentAppName(_ appName: String) -> Bool {
    !(appName.contains("'") && appName.contains("\""))
}

/// Renders `summon-app <appName>` as a TOML string value that survives both the TOML
/// parser and `splitArgs()`.
///
/// Neither layer supports escaping inside single quotes: a TOML literal string
/// (`'...'`) cannot contain `'` at all, and `splitArgs()` treats the first matching
/// quote as the end of the argument. So each layer picks the quote character its
/// content does not use.
///
/// Requires `canRepresentAppName(appName)`.
func summonAppTomlValue(appName: String) -> String {
    let command = summonAppCommand(appName: appName)
    if !command.contains("'") {
        return "'\(command)'" // TOML literal string, no escaping needed
    }
    // TOML basic string
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

/// `summon-app <appName>`, quoted for `splitArgs()`. Requires `canRepresentAppName(appName)`.
private func summonAppCommand(appName: String) -> String {
    let argQuote = appName.contains("\"") ? "'" : "\""
    return "summon-app \(argQuote)\(appName)\(argQuote)"
}

// MARK: - Config values

/// Sets `key` to `value` (already TOML-encoded, e.g. `true` or `'off'`) inside `[table]`, or at
/// the top level when `table` is nil, and writes the config file. With no config file yet, it
/// starts from a copy of the default config, so defaults like `persistent-workspaces` survive.
func setConfigValue(table: String?, key: String, value: String) throws {
    let file = try configFileForEditing(contentIfMissing: readConfigLines(from: defaultConfigUrl).lines)
    try writeConfigLines(setTomlValueInLines(file.lines, table: table, key: key, value: value), to: file.url, separator: file.separator)
}

/// Pure line-manipulation logic for `setConfigValue`, separated from file I/O for testability.
/// Replaces the existing entry (keeping its indentation and trailing comment) or adds a new one.
/// `table` and `key` are bare keys; `table` may be dotted.
func setTomlValueInLines(_ lines: [String], table: String?, key: String, value: String) throws -> [String] {
    let content = try setTomlValueInLinesUnverified(lines, table: table, key: key, value: value)
    let path = (table?.split(separator: ".").map(String.init) ?? []) + [key]
    guard let parsedValue = (try? TOMLTable(string: "value = \(value)"))?["value"].map(TomlData.init) else {
        throw ConfigWriterError.unsupportedEdit(path.joined(separator: "."))
    }
    try verifyTomlEdit(from: lines, to: content, path: path) { $0.set(path, parsedValue) }
    return content
}

private func setTomlValueInLinesUnverified(_ lines: [String], table: String?, key: String, value: String) throws -> [String] {
    let topLevel = 0 ..< tomlSectionEnd(lines, sectionStart: -1)
    guard let table else {
        return setTomlEntry(lines, in: topLevel, key: key, value: value, defaultIndent: "")
    }
    if let header = lines.firstIndex(where: { tomlTableHeader($0) == table }) {
        let section = header + 1 ..< tomlSectionEnd(lines, sectionStart: header)
        return setTomlEntry(lines, in: section, key: key, value: value, defaultIndent: "    ")
    }
    // The table may be written without a header, as `table = { ... }` or `table.key = ...`
    let topLevelKeys = tomlEntries(lines, in: topLevel).map(\.key)
    if topLevelKeys.contains(table) {
        throw ConfigWriterError.inlineTable(table)
    }
    if topLevelKeys.contains(where: { $0.hasPrefix(table + ".") }) {
        return setTomlEntry(lines, in: topLevel, key: "\(table).\(key)", value: value, defaultIndent: "")
    }
    var content = lines
    while content.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { content.removeLast() }
    if !content.isEmpty { content.append("") }
    return content + ["[\(table)]", "    \(key) = \(value)", ""]
}

private func setTomlEntry(_ lines: [String], in range: Range<Int>, key: String, value: String, defaultIndent: String) -> [String] {
    func indent(_ line: String) -> String { String(line.prefix { $0 == " " || $0 == "\t" }) }
    var content = lines
    let entries = tomlEntries(lines, in: range)
    if let entry = entries.first(where: { $0.key == key }) {
        let line = lines[entry.lines.lowerBound]
        // A trailing comment can only be kept when the old value fits on one line
        let comment = entry.lines.count == 1 ? String(line[tomlCommentStart(line)...]) : ""
        let newLine = "\(indent(line))\(key) = \(value)" + (comment.isEmpty ? "" : " \(comment)")
        content.replaceSubrange(entry.lines, with: [newLine])
    } else {
        let lastEntry = entries.last
        let newLine = "\(lastEntry.map { indent(lines[$0.lines.lowerBound]) } ?? defaultIndent)\(key) = \(value)"
        content.insert(newLine, at: lastEntry?.lines.upperBound ?? range.lowerBound)
    }
    return content
}

/// The `key = value` entries in `range`, each with the lines its value spans.
/// Keys are normalized with `tomlNormalizedKey`.
private func tomlEntries(_ lines: [String], in range: Range<Int>) -> [(key: String, lines: Range<Int>)] {
    var result: [(key: String, lines: Range<Int>)] = []
    var index = range.lowerBound
    while index < range.upperBound {
        let span = min(tomlEntryLineCount(lines, at: index), range.upperBound - index)
        let line = lines[index]
        let code = line[..<tomlCommentStart(line)]
        if let eq = code.firstIndex(of: "=") {
            let key = tomlNormalizedKey(code[..<eq])
            if !key.isEmpty { result.append((key, index ..< index + span)) }
        }
        index += span
    }
    return result
}

// MARK: - Binding Matching

/// The key name that `mapping` resolves to `key`. Prefers the qwerty name, so a plain qwerty
/// config keeps getting the names it always did.
func configKeyNotation(for key: Key, in mapping: [String: Key]) -> String? {
    let qwertyName = key.toString()
    if mapping[qwertyName] == key { return qwertyName }
    return mapping.filter { $0.value == key }.keys.min()
}

/// Remove bindings within a binding section that bind the same key+modifiers,
/// regardless of modifier order in the text (e.g. "shift-cmd-k" matches "cmd-shift-k").
/// `key` is the physical key in qwerty notation; line keys are resolved through `keyMapping`
/// so a binding written under another layout still matches.
/// A binding whose value spans several lines is removed as a whole.
func removeMatchingBindingLines(
    _ lines: [String],
    sectionStart: Int,
    sectionEnd: Int,
    key: String,
    modifiers: NSEvent.ModifierFlags,
    keyMapping: [String: Key] = keyNotationToKeyCode,
) -> [String] {
    var result = Array(lines[...sectionStart])
    var index = sectionStart + 1
    while index < sectionEnd {
        let span = min(tomlEntryLineCount(lines, at: index), sectionEnd - index)
        if !bindingLineMatches(lines[index], key: key, modifiers: modifiers, keyMapping: keyMapping) {
            result += lines[index ..< index + span]
        }
        index += span
    }
    return result + lines[sectionEnd...]
}

private func bindingLineMatches(_ line: String, key: String, modifiers: NSEvent.ModifierFlags, keyMapping: [String: Key]) -> Bool {
    let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
    guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { return false }
    // Extract the binding key (everything before " =" or "="). A quoted key can contain `=` itself
    let keyEnd: String.Index
    if let quote = trimmed.first, quote == "\"" || quote == "'" {
        guard let close = trimmed.dropFirst().firstIndex(of: quote) else { return false }
        keyEnd = trimmed.index(after: close)
    } else {
        keyEnd = trimmed.startIndex
    }
    guard let eqIndex = trimmed[keyEnd...].firstIndex(of: "=") else { return false }
    let bindingKey = trimmed[trimmed.startIndex ..< eqIndex].trimmingCharacters(in: CharacterSet.whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return bindingKeyMatches(bindingKey, key: key, modifiers: modifiers, keyMapping: keyMapping)
}

/// Whether the binding key `bindingKey` (e.g. `cmd-shift-k`) binds `key` with exactly `modifiers`.
private func bindingKeyMatches(_ bindingKey: String, key: String, modifiers: NSEvent.ModifierFlags, keyMapping: [String: Key]) -> Bool {
    // Parse the binding key into parts: the last part is the key, everything before is modifiers
    let parts = bindingKey.split(separator: "-")
    guard let lastPart = parts.last else { return false }
    if let physicalKey = keyNotationToKeyCode[key] {
        guard keyMapping[String(lastPart)] == physicalKey else { return false }
    } else {
        guard String(lastPart) == key else { return false }
    }
    // Parse modifiers from the line
    let lineMods = parts.dropLast().reduce(NSEvent.ModifierFlags()) { flags, part in
        if let mod = modifiersMap[String(part)] { return flags.union(mod) }
        return flags
    }
    return lineMods == modifiers
}

// MARK: - Edit verification

/// A copy of a parsed TOML value. TOMLKit values point into their parent table's memory.
private indirect enum TomlData: Equatable {
    case table([String: TomlData])
    case array([TomlData])
    case string(String)
    case int(Int)
    /// A bit pattern, with every NaN made the same one, because NaN never equals itself as a `Double`
    case double(bitPattern: UInt64)
    case bool(Bool)
    case dateOrTime(String)

    init(_ value: TOMLValueConvertible) {
        self = switch value.type {
            case .table: .table(Dictionary(uniqueKeysWithValues: (value.table ?? TOMLTable()).map { ($0, TomlData($1)) }))
            case .array: .array((value.array ?? TOMLArray()).map { TomlData($0) })
            case .string: .string(value.string ?? "")
            case .int: .int(value.int ?? 0)
            case .double: .double(bitPattern: (value.double.map { $0.isNaN ? .nan : $0 } ?? 0).bitPattern)
            case .bool: .bool(value.bool ?? false)
            case .date, .time, .dateTime: .dateOrTime(value.tomlValue.debugDescription)
        }
    }
}

/// Every table and value in a parsed config, keyed by its path. Each table is present too, as an empty
/// table, so comparing two configs entry by entry also compares which tables they define.
private struct ParsedTomlEntries: Equatable {
    var values: [[String]: TomlData] = [:]

    init(_ table: TOMLTable, at path: [String] = []) {
        if !path.isEmpty { values[path] = .table([:]) }
        for (key, value) in table {
            if let subtable = value.table {
                values.merge(ParsedTomlEntries(subtable, at: path + [key]).values) { $1 }
            } else {
                values[path + [key]] = TomlData(value)
            }
        }
    }

    /// Sets the value at `path`, creating the tables above it as a TOML parser would.
    mutating func set(_ path: [String], _ value: TomlData) {
        for depth in 1 ..< path.count where values[Array(path.prefix(depth))] == nil {
            values[Array(path.prefix(depth))] = .table([:])
        }
        values[path] = value
    }
}

/// Edits go through the line functions so comments and formatting survive, which no TOML serializer
/// preserves. The line functions only understand common config shapes, so the TOML parser checks every
/// edit: `edited` must parse to exactly `original` with `expectedChange` applied. Any other result is
/// refused, so a config shape the line functions misread produces an error instead of a damaged file.
private func verifyTomlEdit(
    from original: [String],
    to edited: [String],
    path: [String],
    expectedChange: (inout ParsedTomlEntries) -> Void,
) throws {
    var expected: ParsedTomlEntries
    do {
        expected = ParsedTomlEntries(try TOMLTable(string: original.joined(separator: "\n")))
    } catch let e as TOMLParseError {
        throw ConfigWriterError.invalidConfig(e.debugDescription)
    }
    expectedChange(&expected)
    guard let actual = try? TOMLTable(string: edited.joined(separator: "\n")), ParsedTomlEntries(actual) == expected else {
        throw ConfigWriterError.unsupportedEdit(path.joined(separator: "."))
    }
}

// MARK: - TOML line scanning

/// The table name of a `[table]` header line, ignoring a trailing comment. Nil for any other line
func tomlTableHeader(_ line: String) -> String? {
    let code = line[..<tomlCommentStart(line)]
    let trimmed = code.trimmingCharacters(in: CharacterSet.whitespaces)
    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }
    return tomlNormalizedKey(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
}

/// A dotted key with the whitespace around its dots and the quotes around each part removed,
/// so `"quick-switcher" . 'enabled'` compares equal to `quick-switcher.enabled`.
/// Quoted parts containing a dot or an escape are left as written; the keys we look up are all bare.
private func tomlNormalizedKey(_ key: some StringProtocol) -> String {
    key.split(separator: ".", omittingEmptySubsequences: false)
        .map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, let quote = trimmed.first, quote == "\"" || quote == "'", trimmed.last == quote else { return trimmed }
            return String(trimmed.dropFirst().dropLast())
        }
        .joined(separator: ".")
}

/// Index of the next table header after `sectionStart`, or `lines.count`. Pass -1 to find
/// where the top-level keys end. Skips over multi-line values so their contents are never read as headers.
private func tomlSectionEnd(_ lines: [String], sectionStart: Int) -> Int {
    var index = sectionStart + 1
    while index < lines.count {
        if tomlTableHeader(lines[index]) != nil { return index }
        index += tomlEntryLineCount(lines, at: index)
    }
    return lines.count
}

/// Number of lines the entry starting at `index` spans. A value continues onto later lines
/// while a multi-line string (`'''` or `"""`) or an array is still open.
private func tomlEntryLineCount(_ lines: [String], at index: Int) -> Int {
    var scanner = TomlValueScanner()
    for i in index ..< lines.count {
        scanner.scan(lines[i])
        if scanner.isComplete { return i - index + 1 }
    }
    return lines.count - index
}

/// Tracks string and array nesting across the lines of one `key = value` entry, so a
/// bracket, quote, or `#` inside any kind of string is never read as TOML syntax.
private struct TomlValueScanner {
    private enum Context { case code, basic, literal, multiLineBasic, multiLineLiteral }
    private var context = Context.code
    private var depth = 0

    /// True when no string or array is left open
    var isComplete: Bool { context == .code && depth <= 0 }

    mutating func scan(_ line: String) {
        let chars = Array(line)
        /// Length of the run of `char` starting at `i`
        func run(_ char: Character, _ i: Int) -> Int {
            chars[i...].prefix { $0 == char }.count
        }
        var i = 0
        scanning: while i < chars.count {
            let char = chars[i]
            switch context {
                case .code:
                    switch char {
                        case "#": break scanning
                        case "[": depth += 1
                        case "]": depth -= 1
                        case "\"", "'":
                            let triple = run(char, i) >= 3
                            if triple { i += 2 }
                            context = switch (char, triple) {
                                case ("\"", false): .basic
                                case ("\"", true): .multiLineBasic
                                case (_, false): .literal
                                case (_, true): .multiLineLiteral
                            }
                        default: break
                    }
                case .basic, .multiLineBasic:
                    if char == "\\" {
                        i += 1 // skip the escaped character
                    } else if char == "\"" {
                        if context == .basic {
                            context = .code
                        } else if run(char, i) >= 3 {
                            // Up to two quotes before the closing `"""` belong to the string
                            i += run(char, i) - 1
                            context = .code
                        }
                    }
                case .literal:
                    if char == "'" { context = .code }
                case .multiLineLiteral:
                    if char == "'" && run(char, i) >= 3 {
                        i += run(char, i) - 1
                        context = .code
                    }
            }
            i += 1
        }
        // Single-line strings cannot continue onto the next line
        if context == .basic || context == .literal { context = .code }
    }
}

/// Index where the trailing comment of `text` starts, or `text.endIndex` if there is none.
/// A `#` inside a quoted string (e.g. `[mode."foo#bar".binding]`) is not a comment.
private func tomlCommentStart(_ text: String) -> String.Index {
    var quote: Character? = nil
    var escaped = false
    for index in text.indices {
        let char = text[index]
        if let q = quote {
            if escaped {
                escaped = false
            } else if char == "\\" && q == "\"" {
                escaped = true
            } else if char == q {
                quote = nil
            }
            continue
        }
        switch char {
            case "'", "\"": quote = char
            case "#": return index
            default: break
        }
    }
    return text.endIndex
}

// MARK: - Helpers

/// Reads a config file as lines without their `\n` or `\r\n` endings, so the line functions never
/// see a `\r`. `separator` is `\r\n` when the file uses it, so the file can be written back as it was.
func readConfigLines(from url: URL) throws -> (lines: [String], separator: String) {
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    return (lines, text.contains("\r\n") ? "\r\n" : "\n")
}

func writeConfigLines(_ lines: [String], to url: URL, separator: String = "\n") throws {
    try writeConfigFile(lines.joined(separator: separator), to: url)
}

/// The config file to edit and its current lines. With no config file yet, it is `~/.airlock.toml` with
/// `contentIfMissing`, created only when the edit is written, so a refused edit leaves no file behind.
private func configFileForEditing(contentIfMissing: @autoclosure () throws -> [String]) throws -> (url: URL, lines: [String], separator: String) {
    switch findCustomConfigUrl() {
        case .file(let url):
            let config = try readConfigLines(from: url)
            return (url, config.lines, config.separator)
        case .noCustomConfigExists:
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
            return (url, try contentIfMissing(), "\n")
        case .ambiguousConfigError(let urls):
            throw ConfigWriterError.ambiguousConfig(urls)
    }
}
