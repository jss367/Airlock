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
    let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
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

/// Number of lines the entry starting at `index` spans. A value that opens a multi-line
/// string (`'''` or `"""`) or an array continues until its closing delimiter.
private func tomlEntryLineCount(_ lines: [String], at index: Int) -> Int {
    let line = lines[index]
    guard !line.trimmingCharacters(in: CharacterSet.whitespaces).hasPrefix("#"),
          let eqIndex = line.firstIndex(of: "=") else { return 1 }
    let value = line[line.index(after: eqIndex)...].trimmingCharacters(in: CharacterSet.whitespaces)
    for delimiter in ["'''", "\"\"\""] where value.hasPrefix(delimiter) {
        if value.dropFirst(delimiter.count).contains(delimiter) { return 1 }
        let closing = lines[(index + 1)...].firstIndex { $0.contains(delimiter) }
        return (closing ?? lines.count - 1) - index + 1
    }
    guard value.hasPrefix("[") else { return 1 }
    var depth = 0
    for i in index ..< lines.count {
        depth += bracketDepthChange(i == index ? value : lines[i])
        if depth <= 0 { return i - index + 1 }
    }
    return lines.count - index
}

/// Net `[` minus `]` outside of quoted strings and comments
private func bracketDepthChange(_ text: String) -> Int {
    var depth = 0
    var quote: Character? = nil
    var escaped = false
    for char in text {
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
            case "#": return depth
            case "[": depth += 1
            case "]": depth -= 1
            default: break
        }
    }
    return depth
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
