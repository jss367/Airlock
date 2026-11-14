import AppKit
import Common
import Foundation
import SwiftUI

struct AirlockRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool

    var pageURL: URL {
        URL(string: "https://github.com/jss367/Airlock/releases/tag/\(tag_name)")!
    }
}

struct ReleaseVersion: Comparable {
    let components: [Int]

    init?(_ value: String) {
        var value = value
        if value.hasPrefix("v") { value.removeFirst() }
        if value.hasSuffix(" SNAPSHOT") { value.removeLast(" SNAPSHOT".count) }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

enum UpdateCheckError: LocalizedError {
    case invalidRelease
    case invalidVersion
    case http(Int)

    var errorDescription: String? {
        switch self {
            case .invalidRelease: "GitHub did not return a valid stable release. Please try again later."
            case .invalidVersion: "Airlock could not compare the installed version with the latest release."
            case .http(404): "No published Airlock release was found."
            case .http(403), .http(429): "GitHub is limiting update requests. Please try again later."
            case .http(let status): "GitHub could not complete the update check (HTTP \(status)). Please try again later."
        }
    }
}

struct UpdateCheckResult {
    let release: AirlockRelease
    let isUpdateAvailable: Bool
}

func checkForAirlockUpdate(
    currentVersion: String,
    fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
) async throws -> UpdateCheckResult {
    let url = URL(string: "https://api.github.com/repos/jss367/Airlock/releases/latest")!
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Airlock", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await fetch(request)
    guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.invalidRelease }
    guard response.statusCode == 200 else { throw UpdateCheckError.http(response.statusCode) }
    let release = try JSONDecoder().decode(AirlockRelease.self, from: data)
    guard !release.draft, !release.prerelease,
          !release.tag_name.contains(" SNAPSHOT"), ReleaseVersion(release.tag_name) != nil
    else { throw UpdateCheckError.invalidRelease }
    guard let installed = ReleaseVersion(currentVersion), let latest = ReleaseVersion(release.tag_name) else {
        throw UpdateCheckError.invalidVersion
    }
    return UpdateCheckResult(release: release, isUpdateAvailable: latest > installed)
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var isChecking = false

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let alert = NSAlert()
        var releaseURL: URL?
        do {
            let result = try await checkForAirlockUpdate(currentVersion: airlockAppVersion)
            if result.isUpdateAvailable {
                alert.messageText = "An Airlock Update Is Available"
                alert.informativeText = "Airlock \(result.release.tag_name) is available. You have \(airlockAppVersion). Open the release page to download and install the update."
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Later")
                releaseURL = result.release.pageURL
            } else {
                alert.messageText = "Airlock Is Up to Date"
                alert.informativeText = "You have Airlock \(airlockAppVersion). The latest published release is \(result.release.tag_name)."
                alert.addButton(withTitle: "OK")
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Unable to Check for Updates"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        Button(checker.isChecking ? "Checking for Updates…" : "Check for Updates…") {
            Task { await checker.check() }
        }
        .disabled(checker.isChecking)
    }
}
