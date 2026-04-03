import AppKit
import Common
import Foundation

enum ConfigWriterError: LocalizedError {
    case ambiguousConfig([URL])
    case writeError(String)

    var errorDescription: String? {
        switch self {
        case .ambiguousConfig(let urls):
            return "Multiple config files found: \(urls.map(\.path).joined(separator: ", "))"
        case .writeError(let msg):
            return "Failed to write config: \(msg)"
        }
    }
}

func addBinding(key: String, appName: String, modifierPrefix: NSEvent.ModifierFlags) throws {
    let (url, lines) = try loadOrCreateConfig()
    let content = addBindingToLines(lines, key: key, appName: appName, modifierPrefix: modifierPrefix)
    let output = content.joined(separator: "\n")
    try output.write(to: url, atomically: true, encoding: .utf8)
}

/// Pure function that adds a binding to config lines without file I/O.
/// Visible to tests via @testable import.
func addBindingToLines(_ lines: [String], key: String, appName: String, modifierPrefix: NSEvent.ModifierFlags) -> [String] {
    var content = lines

    let modStr = modifierPrefix.toString()
    let escapedAppName = appName.replacingOccurrences(of: "'", with: "'\\''")
    let bindingLine = "    \(modStr)-\(key) = 'summon-app \"\(escapedAppName)\"'"

    // Find [mode.main.binding] section
    if let sectionIndex = content.firstIndex(where: { $0.trimmingCharacters(in: CharacterSet.whitespaces) == "[mode.main.binding]" }) {
        // Find the insertion point: before the next section header or end of file
        var insertIndex = content.count
        for i in (sectionIndex + 1)..<content.count {
            let trimmed = content[i].trimmingCharacters(in: CharacterSet.whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                insertIndex = i
                break
            }
        }

        // Remove existing binding for this key+modifier (matching by parsed modifiers, not string)
        content = removeMatchingBindingLines(content, sectionStart: sectionIndex, sectionEnd: insertIndex, key: key, modifiers: modifierPrefix)

        // Recalculate insert index after removal
        var newInsertIndex = content.count
        for i in (sectionIndex + 1)..<content.count {
            let trimmed = content[i].trimmingCharacters(in: CharacterSet.whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                newInsertIndex = i
                break
            }
        }

        content.insert(bindingLine, at: newInsertIndex)
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

func removeBinding(key: String, modifierPrefix: NSEvent.ModifierFlags) throws {
    let configFile = findCustomConfigUrl()

    guard case .file(let url) = configFile else {
        return
    }

    let text = try String(contentsOf: url, encoding: .utf8)
    var lines = text.components(separatedBy: "\n")

    // Find [mode.main.binding] section
    guard let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: CharacterSet.whitespaces) == "[mode.main.binding]" }) else {
        return
    }

    // Find the end of this section
    var sectionEnd = lines.count
    for i in (sectionIndex + 1)..<lines.count {
        let trimmed = lines[i].trimmingCharacters(in: CharacterSet.whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            sectionEnd = i
            break
        }
    }

    lines = removeMatchingBindingLines(lines, sectionStart: sectionIndex, sectionEnd: sectionEnd, key: key, modifiers: modifierPrefix)

    let output = lines.joined(separator: "\n")
    try output.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Binding Matching

/// Remove lines within a binding section that bind the same key+modifiers,
/// regardless of modifier order in the text (e.g. "shift-cmd-k" matches "cmd-shift-k").
private func removeMatchingBindingLines(_ lines: [String], sectionStart: Int, sectionEnd: Int, key: String, modifiers: NSEvent.ModifierFlags) -> [String] {
    return lines.enumerated().filter { index, line in
        guard index > sectionStart && index < sectionEnd else { return true }
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
        guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { return true }
        // Extract the binding key (everything before " =" or "=")
        guard let eqIndex = trimmed.firstIndex(of: "=") else { return true }
        let bindingKey = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: CharacterSet.whitespaces)
        // Parse the binding key into parts: the last part is the key, everything before is modifiers
        let parts = bindingKey.split(separator: "-")
        guard let lastPart = parts.last, String(lastPart) == key else { return true }
        // Parse modifiers from the line
        let lineMods = parts.dropLast().reduce(NSEvent.ModifierFlags()) { flags, part in
            if let mod = modifiersMap[String(part)] { return flags.union(mod) }
            return flags
        }
        return lineMods != modifiers
    }.map(\.1)
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
