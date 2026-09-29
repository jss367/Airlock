import AppKit

/// Cancel pending screenshots when focus changes, before the overlay panel exists.
@MainActor
final class MissionControlCaptureMonitor {
    private let appNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        appNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
    ) {
        self.appNotifications = appNotifications
        self.workspaceNotifications = workspaceNotifications
    }

    func start(onCancel: @escaping @MainActor () -> Void) {
        stop()
        // Airlock may already be inactive when its global shortcut starts capture, so also
        // watch workspace activation to catch switches between two other applications.
        let notifications: [(NotificationCenter, Notification.Name)] = [
            (appNotifications, NSApplication.didResignActiveNotification),
            (workspaceNotifications, NSWorkspace.didActivateApplicationNotification),
        ]
        for (center, name) in notifications {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onCancel() }
            }
            observers.append((center, observer))
        }
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
