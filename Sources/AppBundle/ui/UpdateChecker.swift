import AppKit
import Combine
import Common
import Sparkle
import SwiftUI

/// Checks for Airlock releases and installs them with Sparkle. resources/Info.plist holds the Sparkle settings.
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private let notificationCenter: NotificationCenter
    private let restoreWindows: @MainActor () -> Void
    private var isRestoringWindowsOnTermination = false

    init(
        notificationCenter: NotificationCenter = .default,
        restoreWindows: @MainActor @escaping () -> Void = {
            _ = terminationHandler.beforeTerminationBlocking(deadline: .now() + terminationHandlerTimeout)
        },
    ) {
        self.notificationCenter = notificationCenter
        self.restoreWindows = restoreWindows
    }

    /// Debug builds have no feed, so they never replace themselves with a release. Their menu item stays disabled.
    static func hasFeed(_ infoDictionary: [String: Any]?) -> Bool {
        (infoDictionary?["SUFeedURL"] as? String)?.isEmpty == false
    }

    func start() {
        guard controller == nil, Self.hasFeed(Bundle.main.infoDictionary) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        self.controller = controller
    }

    func check() {
        // Airlock has no Dock icon, so its windows open behind the active app unless it activates first
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Sparkle's installer asks Airlock to quit, which skips the window restoring that "Quit Airlock" does first.
    /// Restore at the last moment: until Airlock exits, a refresh session can hide the windows again.
    func restoreWindowsOnTermination() {
        guard !isRestoringWindowsOnTermination else { return }
        isRestoringWindowsOnTermination = true
        let restoreWindows = restoreWindows
        // The queue is nil so that the block finishes before the process exits
        notificationCenter.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { restoreWindows() }
        }
    }
}

extension UpdateChecker: SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_: SPUUpdater) {
        restoreWindowsOnTermination()
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        Button("Check for Updates…") { checker.check() }
            .disabled(!checker.canCheck)
    }
}
