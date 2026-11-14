import AppKit
import Common
import SwiftUI

// MARK: - Global State

// The functions other files call keep their original "Mission Control" names. The feature itself
// is the workspace overview, so it isn't confused with the macOS Mission Control.

@MainActor private var workspaceOverviewPanel: WorkspaceOverviewPanel?
/// The open overview. Unit tests open it without a panel
@MainActor private var workspaceOverviewState: WorkspaceOverviewState?
@MainActor private let workspaceOverviewFocusMonitor = WorkspaceOverviewFocusMonitor()
/// The last thumbnail captured for each window, shown right away the next time the overview opens
@MainActor private var workspaceOverviewThumbnailCache: [UInt32: CGImage] = [:]
/// The last title read for each window. Reading titles is async, so without this every open
/// would show app names first and swap in the real titles a moment later
@MainActor private var workspaceOverviewTitleCache: [UInt32: String] = [:]
/// When the overview's own key handling last closed it on its configured shortcut
@MainActor private var workspaceOverviewClosedByShortcutAt: TimeInterval?

@MainActor var isMissionControlOpen: Bool { workspaceOverviewState != nil }

@MainActor
func toggleMissionControl() {
    if isMissionControlOpen {
        dismissMissionControl()
        return
    }
    // Paused Airlock can't act on a selection, and pausing closes the panel. Stay closed
    guard sessionCoordinator.isEnabled else { return }
    // The key press that just closed the overview can also arrive as its registered hotkey,
    // which must not open it again
    if let closedAt = workspaceOverviewClosedByShortcutAt {
        workspaceOverviewClosedByShortcutAt = nil
        if ProcessInfo.processInfo.systemUptime - closedAt < 0.3 { return }
    }

    // Capturing without screen-recording access makes macOS prompt for it. Opening the overview must
    // never do that, so without access the tiles show app icons, even for windows captured before it was revoked
    let canCaptureWindows = !isUnitTest && CGPreflightScreenCaptureAccess()
    workspaceOverviewThumbnailCache = canCaptureWindows
        ? workspaceOverviewThumbnailCache.filter { Window.get(byId: $0.key) != nil }
        : [:]
    workspaceOverviewTitleCache = workspaceOverviewTitleCache.filter { Window.get(byId: $0.key) != nil }

    let screen = NSScreen.main
    let state = WorkspaceOverviewState(
        workspaces: buildOverviewWorkspaces(),
        thumbnails: workspaceOverviewThumbnailCache,
        gridColumns: WorkspaceOverviewLayout.gridColumns(availableWidth: screen?.frame.width ?? 1440),
    )
    workspaceOverviewState = state
    if isUnitTest { return }

    workspaceOverviewFocusMonitor.start {
        dismissMissionControl(restoreFocus: false)
    }
    // The panel opens right away with cached thumbnails and placeholders, and fresh captures fill in
    // behind it. The panel can't end up in them: captureWindowImages captures each window by itself
    let panel = WorkspaceOverviewPanel(state: state, screen: screen)
    workspaceOverviewPanel = panel
    panel.show()
    panel.loadWindowDetails(captureThumbnails: canCaptureWindows)
}

/// Pass `restoreFocus: false` when something else already took focus.
/// Otherwise the panel activated Airlock, and nothing else hands focus back to a real window.
@MainActor
func dismissMissionControl(restoreFocus: Bool = true) {
    guard isMissionControlOpen else { return }
    workspaceOverviewFocusMonitor.stop()
    workspaceOverviewState = nil
    let panel = workspaceOverviewPanel
    workspaceOverviewPanel = nil
    panel?.close()
    if restoreFocus {
        focus.windowOrNil?.nativeFocus()
    }
}

/// The overview's shortcut was pressed while it had the keyboard
@MainActor
func dismissWorkspaceOverviewFromShortcut() {
    guard isMissionControlOpen else { return }
    workspaceOverviewClosedByShortcutAt = ProcessInfo.processInfo.systemUptime
    dismissMissionControl()
}

// MARK: - Workspace List

@MainActor
private func buildOverviewWorkspaces() -> [OverviewWorkspace] {
    let focusedWorkspaceName = focus.workspace.name
    let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] ?? []
    var boundsById: [UInt32: (order: Int, rect: CGRect)] = [:]
    for (order, info) in windowInfoList.enumerated() {
        guard let windowNumber = info[kCGWindowNumber] as? NSNumber,
              let bounds = info[kCGWindowBounds] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
        else { continue }
        boundsById[windowNumber.uint32Value] = (order, CGRect(x: x, y: y, width: width, height: height))
    }

    var iconsByPid: [Int32: NSImage?] = [:]
    return workspacesForUi().map { workspace in
        let monitorRect = workspace.workspaceMonitor.rect
        let windows = workspace.allLeafWindowsRecursive.map { window in
            let pid = window.app.pid
            let icon = iconsByPid[pid] ?? NSRunningApplication(processIdentifier: pid)?.icon
            iconsByPid[pid] = .some(icon)

            var unitFrame: CGRect? = nil
            if var rect = boundsById[window.windowId]?.rect, monitorRect.width > 0, monitorRect.height > 0 {
                // Windows of hidden workspaces all sit parked in one corner, so draw them where they'll be when shown
                if let unhidden = (window as? MacWindow)?.rectWhenUnhidden(currentSize: rect.size) {
                    rect = CGRect(x: unhidden.topLeftX, y: unhidden.topLeftY, width: unhidden.width, height: unhidden.height)
                }
                unitFrame = CGRect(
                    x: (rect.minX - monitorRect.topLeftX) / monitorRect.width,
                    y: (rect.minY - monitorRect.topLeftY) / monitorRect.height,
                    width: rect.width / monitorRect.width,
                    height: rect.height / monitorRect.height,
                )
            }
            return OverviewWindow(
                id: window.windowId,
                appName: window.app.name ?? "Unknown",
                title: workspaceOverviewTitleCache[window.windowId] ?? "",
                icon: icon,
                unitFrame: unitFrame,
                stackingOrder: boundsById[window.windowId]?.order ?? 0,
            )
        }
        return OverviewWorkspace(
            name: workspace.name,
            isFocused: workspace.name == focusedWorkspaceName,
            windows: windows,
            monitorAspectRatio: monitorRect.height > 0 ? monitorRect.width / monitorRect.height : 1.6,
        )
    }
}

// MARK: - Activation

/// Focus the chosen workspace or window, then close the overview that chose it
@MainActor
private func activateOverviewTarget(_ target: WorkspaceOverviewTarget, from state: WorkspaceOverviewState) {
    // Airlock's focus is stale while paused, so don't send the user back to it
    guard let token: RunSessionGuard = .isServerEnabled else { return dismissMissionControl(restoreFocus: false) }
    Task {
        do {
            try await runLightSession(.menuBarButton, token) {
                switch target {
                    case .workspace(let name):
                        focusWorkspaceFromUi(Workspace.get(byName: name))
                    case .window(let windowId):
                        if let window = Window.get(byId: windowId) { focusWindowFromUi(window) }
                }
            }
        } catch is CancellationError {
            if workspaceOverviewState === state { dismissMissionControl(restoreFocus: false) }
            return
        } catch {
            switch target {
                case .workspace:
                    reportAppError(error, operation: "Switching workspace from the workspace overview", userMessage: "Airlock could not switch workspace.")
                case .window:
                    reportAppError(error, operation: "Focusing a window from the workspace overview", userMessage: "Airlock could not focus the window.")
            }
        }
        if workspaceOverviewState === state { dismissMissionControl() }
    }
}

// MARK: - Panel

@MainActor
private final class WorkspaceOverviewPanel: NSPanelHud {
    private let state: WorkspaceOverviewState
    private let keyMonitor = PanelKeyMonitor()
    private var detailTasks: [Task<Void, Never>] = []

    // Hover tracking and VoiceOver only reach the cards and tiles of a key window
    override var canBecomeKey: Bool { true }

    init(state: WorkspaceOverviewState, screen: NSScreen?) {
        self.state = state
        super.init()
        let content = WorkspaceOverviewContent(
            state: state,
            width: screen?.frame.width ?? 1440,
            onActivate: { [state] in activateOverviewTarget($0, from: state) },
        )
        self.contentView = NSHostingView(rootView: content)
        if let screen {
            self.setFrame(screen.frame, display: true)
        }

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.setAccessibilityLabel("Workspace Overview")
    }

    func show() {
        keyMonitor.install { [weak self] in self?.handleKeyEvent($0) ?? false }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func close() {
        keyMonitor.remove()
        detailTasks.forEach { $0.cancel() }
        detailTasks = []
        super.close()
    }

    /// Fill in real window titles and fresh thumbnails after the panel is already on screen
    func loadWindowDetails(captureThumbnails: Bool) {
        detailTasks.append(Task { [state] in
            await state.refreshWindowTitles(onTitle: { workspaceOverviewTitleCache[$0] = $1 })
        })
        guard captureThumbnails else { return }
        let windowIds = state.windowIdsFromSelectedWorkspace
        detailTasks.append(Task { [state] in
            await captureWindowImages(orderedWindowIds: windowIds) { windowId, image in
                state.thumbnails[windowId] = image
                workspaceOverviewThumbnailCache[windowId] = image
            }
        })
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if isWorkspaceOverviewShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags, config) {
            // The press that opened the overview may still be held down
            if !event.isARepeat { Task { @MainActor in dismissWorkspaceOverviewFromShortcut() } }
            return true
        }
        switch workspaceOverviewKeyAction(keyCode: event.keyCode, hasShift: event.modifierFlags.contains(.shift)) {
            case .move(let direction): state.move(direction)
            case .cycleWindow(let offset): state.cycleWindow(offset: offset)
            case .activate: if let target = state.selectedTarget { activateOverviewTarget(target, from: state) }
            case .close: Task { @MainActor in dismissMissionControl() }
            case nil: break
        }
        // The overview owns the keyboard while open. Keys it doesn't use would only beep
        return true
    }
}
