import AppKit

/// Closes the workspace overview when another app takes focus. Its full-screen panel doesn't hide
/// on deactivate, so it would otherwise stay on top of the app the user switched to.
@MainActor
final class WorkspaceOverviewFocusMonitor {
    private let appNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private let ownPid: pid_t
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        appNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        ownPid: pid_t = ProcessInfo.processInfo.processIdentifier,
    ) {
        self.appNotifications = appNotifications
        self.workspaceNotifications = workspaceNotifications
        self.ownPid = ownPid
    }

    func start(onFocusLost: @escaping @MainActor () -> Void) {
        stop()
        let resignObserver = appNotifications.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { onFocusLost() }
        }
        // Airlock may still be inactive when its global shortcut opens the overview, so also watch
        // workspace activation to catch switches between two other applications. Opening the
        // overview activates Airlock itself, which must not close it.
        let ownPid = ownPid
        let activateObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isOwnActivation = app?.processIdentifier == ownPid
            MainActor.assumeIsolated { if !isOwnActivation { onFocusLost() } }
        }
        observers = [(appNotifications, resignObserver), (workspaceNotifications, activateObserver)]
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
