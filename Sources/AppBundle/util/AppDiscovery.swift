import AppKit

struct InstalledApp: Hashable {
    let name: String
    let bundleIdentifier: String?
    let url: URL
    let icon: NSImage

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

@MainActor
func discoverInstalledApps() -> [InstalledApp] {
    let fileManager = FileManager.default
    let searchDirs = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    var apps: [URL: InstalledApp] = [:]

    for dir in searchDirs {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { continue }

        for url in urls {
            addApp(url: url, into: &apps)

            // One level of subdirectories (e.g. /Applications/Utilities/)
            if url.hasDirectoryPath && url.pathExtension != "app" {
                if let subUrls = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for subUrl in subUrls {
                        addApp(url: subUrl, into: &apps)
                    }
                }
            }
        }
    }

    return Array(apps.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func addApp(url: URL, into apps: inout [URL: InstalledApp]) {
    guard url.pathExtension == "app" else { return }
    let name = url.deletingPathExtension().lastPathComponent
    let bundleId = Bundle(url: url)?.bundleIdentifier
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    apps[url] = InstalledApp(name: name, bundleIdentifier: bundleId, url: url, icon: icon)
}

// MARK: - Lightweight discovery (no AppKit, safe for background threads)

struct InstalledAppInfo: Hashable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let url: URL
}

func discoverInstalledAppInfo() async -> [InstalledAppInfo] {
    let fileManager = FileManager.default
    let searchDirs = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    var apps: [URL: InstalledAppInfo] = [:]

    for dir in searchDirs {
        guard !Task.isCancelled else { break }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { continue }

        for url in urls {
            addAppInfo(url: url, into: &apps)

            if url.hasDirectoryPath && url.pathExtension != "app" {
                if let subUrls = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for subUrl in subUrls {
                        addAppInfo(url: subUrl, into: &apps)
                    }
                }
            }
        }
    }

    return Array(apps.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func addAppInfo(url: URL, into apps: inout [URL: InstalledAppInfo]) {
    guard url.pathExtension == "app" else { return }
    let name = url.deletingPathExtension().lastPathComponent
    let bundleId = Bundle(url: url)?.bundleIdentifier
    apps[url] = InstalledAppInfo(name: name, bundleIdentifier: bundleId, url: url)
}
