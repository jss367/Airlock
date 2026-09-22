import AppKit
import Common
import Foundation

enum ConfigWriterError: LocalizedError {
    case ambiguousConfig([URL])
    case writeError(String)
    case unrepresentableAppName(String)

    var errorDescription: String? {
        switch self {
            case .ambiguousConfig(let urls):
                return "Multiple config files found: \(urls.map(\.path).joined(separator: ", "))"
            case .writeError(let msg):
                return "Failed to write config: \(msg)"
            case .unrepresentableAppName(let name):
                return "Cannot bind '\(name)': app names containing both ' and \" are not supported"
        }
    }
}

func addBinding(key: String, appName: String, modifierPrefix: NSEvent.ModifierFlags) throws {
    guard canRepresentAppName(appName) else { throw ConfigWriterError.unrepresentableAppName(appName) }
    let (url, lines) = try loadOrCreateConfig()
    let content = addBindingToLines(lines, key: key, appName: appName, modifierPrefix: modifierPrefix)
    let output = content.joined(separator: "\n")
    try output.write(to: url, atomically: true, encoding: .utf8)
}

/// Pure line-manipulation logic for adding a binding, separated from file I/O for testability.
func addBindingToLines(_ lines: [String], key: String, appName: String, modifierPrefix: NSEvent.ModifierFlags) -> [String] {
    var content = lines

    let modStr = modifierPrefix.toString()
    let bindingLine = "    \(modStr)-\(key) = \(summonAppTomlValue(appName: appName))"

    // Find [mode.main.binding] section
    if let sectionIndex = content.firstIndex(where: { tomlTableHeader($0) == "mode.main.binding" }) {
        // Remove existing binding for this key+modifier (matching by parsed modifiers, not string)
        let sectionEnd = tomlSectionEnd(content, sectionStart: sectionIndex)
        content = removeMatchingBindingLines(content, sectionStart: sectionIndex, sectionEnd: sectionEnd, key: key, modifiers: modifierPrefix)

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

    return content
}

// periphery:ignore
func removeBinding(key: String, modifierPrefix: NSEvent.ModifierFlags) throws {
    let configFile = findCustomConfigUrl()

    guard case .file(let url) = configFile else {
        return
    }

    let text = try String(contentsOf: url, encoding: .utf8)
    var lines = text.components(separatedBy: "\n")

    // Find [mode.main.binding] section
    guard let sectionIndex = lines.firstIndex(where: { tomlTableHeader($0) == "mode.main.binding" }) else {
        return
    }
    let sectionEnd = tomlSectionEnd(lines, sectionStart: sectionIndex)

    lines = removeMatchingBindingLines(lines, sectionStart: sectionIndex, sectionEnd: sectionEnd, key: key, modifiers: modifierPrefix)

    let output = lines.joined(separator: "\n")
    try output.write(to: url, atomically: true, encoding: .utf8)
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
    let argQuote = appName.contains("\"") ? "'" : "\""
    let command = "summon-app \(argQuote)\(appName)\(argQuote)"
    if !command.contains("'") {
        return "'\(command)'" // TOML literal string, no escaping needed
    }
    // TOML basic string
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

// MARK: - Binding Matching

/// Remove bindings within a binding section that bind the same key+modifiers,
/// regardless of modifier order in the text (e.g. "shift-cmd-k" matches "cmd-shift-k").
/// A binding whose value spans several lines is removed as a whole.
func removeMatchingBindingLines(_ lines: [String], sectionStart: Int, sectionEnd: Int, key: String, modifiers: NSEvent.ModifierFlags) -> [String] {
    var result = Array(lines[...sectionStart])
    var index = sectionStart + 1
    while index < sectionEnd {
        let span = min(tomlEntryLineCount(lines, at: index), sectionEnd - index)
        if !bindingLineMatches(lines[index], key: key, modifiers: modifiers) {
            result += lines[index ..< index + span]
        }
        index += span
    }
    return result + lines[sectionEnd...]
}

private func bindingLineMatches(_ line: String, key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
    let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
    guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { return false }
    // Extract the binding key (everything before " =" or "=")
    guard let eqIndex = trimmed.firstIndex(of: "=") else { return false }
    let bindingKey = trimmed[trimmed.startIndex ..< eqIndex].trimmingCharacters(in: CharacterSet.whitespaces)
    // Parse the binding key into parts: the last part is the key, everything before is modifiers
    let parts = bindingKey.split(separator: "-")
    guard let lastPart = parts.last, String(lastPart) == key else { return false }
    // Parse modifiers from the line
    let lineMods = parts.dropLast().reduce(NSEvent.ModifierFlags()) { flags, part in
        if let mod = modifiersMap[String(part)] { return flags.union(mod) }
        return flags
    }
    return lineMods == modifiers
}

// MARK: - TOML line scanning

/// The table name of a `[table]` header line, ignoring a trailing comment. Nil for any other line
private func tomlTableHeader(_ line: String) -> String? {
    let code = line[..<tomlCommentStart(line)]
    let trimmed = code.trimmingCharacters(in: CharacterSet.whitespaces)
    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: CharacterSet.whitespaces)
}

/// Index of the next table header after `sectionStart`, or `lines.count`.
/// Skips over multi-line values so their contents are never read as headers.
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

private func loadOrCreateConfig() throws -> (URL, [String]) {
    let configFile = findCustomConfigUrl()

    switch configFile {
        case .file(let url):
            let text = try String(contentsOf: url, encoding: .utf8)
            return (url, text.components(separatedBy: "\n"))

        case .noCustomConfigExists:
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
            let initial = "[mode.main.binding]\n"
            try initial.write(to: url, atomically: true, encoding: .utf8)
            return (url, initial.components(separatedBy: "\n"))

        case .ambiguousConfigError(let urls):
            throw ConfigWriterError.ambiguousConfig(urls)
    }
}
