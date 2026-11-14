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
    scanInstalledApps().map {
        InstalledApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier, url: $0.url, icon: NSWorkspace.shared.icon(forFile: $0.url.path))
    }
}

// MARK: - Lightweight discovery (no AppKit, safe for background threads)

struct InstalledAppInfo: Hashable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let url: URL
}

/// Scans the application folders off the caller's actor
@concurrent
func discoverInstalledAppInfo() async -> [InstalledAppInfo] {
    scanInstalledApps()
}

/// Sorted by name. Stops early, with a partial list, when the surrounding task is canceled
private func scanInstalledApps() -> [InstalledAppInfo] {
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
            options: [.skipsHiddenFiles],
        ) else { continue }

        for url in urls {
            addAppInfo(url: url, into: &apps)

            // One level of subdirectories (e.g. /Applications/Utilities/)
            if url.hasDirectoryPath && url.pathExtension != "app" {
                if let subUrls = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles],
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
