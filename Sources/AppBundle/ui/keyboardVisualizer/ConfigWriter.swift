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
    var content = lines

    let modStr = modifierPrefix.toString()
    let bindingLine = "    \(modStr)-\(key) = 'exec-and-forget open -a \"\(appName)\"'"

    // Find [mode.main.binding] section
    if let sectionIndex = content.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[mode.main.binding]" }) {
        // Find the insertion point: before the next section header or end of file
        var insertIndex = content.count
        for i in (sectionIndex + 1)..<content.count {
            let trimmed = content[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                insertIndex = i
                break
            }
        }

        // Remove existing binding for this key+modifier if present
        let prefix = "\(modStr)-\(key)"
        content = content.enumerated().filter { index, line in
            guard index > sectionIndex && index < insertIndex else { return true }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("\(prefix) =") && !trimmed.hasPrefix("\(prefix)=")
        }.map(\.1)

        // Recalculate insert index after removal
        var newInsertIndex = content.count
        for i in (sectionIndex + 1)..<content.count {
            let trimmed = content[i].trimmingCharacters(in: .whitespaces)
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

    let output = content.joined(separator: "\n")
    try output.write(to: url, atomically: true, encoding: .utf8)
}

func removeBinding(key: String, modifierPrefix: NSEvent.ModifierFlags) throws {
    let configFile = findCustomConfigUrl()

    guard case .file(let url) = configFile else {
        // Nothing to remove if there's no config file
        return
    }

    let text = try String(contentsOf: url, encoding: .utf8)
    var lines = text.components(separatedBy: "\n")

    let modStr = modifierPrefix.toString()
    let prefix = "\(modStr)-\(key)"

    // Find [mode.main.binding] section
    guard let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[mode.main.binding]" }) else {
        return // Section doesn't exist, nothing to remove
    }

    // Find the end of this section
    var sectionEnd = lines.count
    for i in (sectionIndex + 1)..<lines.count {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            sectionEnd = i
            break
        }
    }

    // Remove matching line
    lines = lines.enumerated().filter { index, line in
        guard index > sectionIndex && index < sectionEnd else { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("\(prefix) =") && !trimmed.hasPrefix("\(prefix)=")
    }.map(\.1)

    let output = lines.joined(separator: "\n")
    try output.write(to: url, atomically: true, encoding: .utf8)
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
