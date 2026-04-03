import AppKit
import Common
import SwiftUI

// MARK: - Global State

@MainActor private var appSwitcherPanel: AppSwitcherPanel?

@MainActor var isAppSwitcherVisible: Bool {
    appSwitcherPanel?.isVisible == true
}

/// Open the app switcher panel and highlight the next/prev app relative to the currently focused one.
@MainActor
func showAppSwitcher(direction: AppCycleDirection) {
    if let panel = appSwitcherPanel, panel.isVisible {
        cycleAppSwitcher(direction: direction)
        return
    }
    let groups = buildAppGroups()
    guard !groups.isEmpty else { return }

    let currentPid = focus.windowOrNil?.app.pid
    let startIndex: Int
    if let currentPid, let idx = groups.firstIndex(where: { $0.pid == currentPid }) {
        let offset = direction == .appPrev ? -1 : 1
        startIndex = (idx + offset + groups.count) % groups.count
    } else {
        startIndex = 0
    }

    let panel = AppSwitcherPanel(groups: groups, selectedAppIndex: startIndex)
    appSwitcherPanel = panel
    panel.show()

    // If Cmd is not currently held (e.g. CLI-triggered `focus app-next`),
    // commit immediately so the panel doesn't stay open indefinitely.
    if !NSEvent.modifierFlags.contains(.command) {
        Task { @MainActor in
            dismissAppSwitcher(commit: true)
        }
        return
    }

    Task {
        await panel.contentState.refreshWindowTitles()
    }
}

/// Move the app highlight in the given direction. Only meaningful when the panel is already visible.
@MainActor
func cycleAppSwitcher(direction: AppCycleDirection) {
    guard let panel = appSwitcherPanel, panel.isVisible else { return }
    switch direction {
        case .appNext:
            panel.contentState.cycleApp(offset: 1)
        case .appPrev:
            panel.contentState.cycleApp(offset: -1)
        case .sameAppNext, .sameAppPrev:
            break // same-app cycling doesn't use the panel
    }
}

/// Dismiss the app switcher. If `commit` is true, focus the selected window/app.
@MainActor
func dismissAppSwitcher(commit: Bool) {
    guard let panel = appSwitcherPanel else { return }
    let selectedGroup: AppGroup?
    let selectedWindowIndex: Int
    if commit {
        selectedGroup = panel.contentState.selectedGroup
        selectedWindowIndex = panel.contentState.selectedWindowIndex
    } else {
        selectedGroup = nil
        selectedWindowIndex = 0
    }
    panel.close()
    appSwitcherPanel = nil

    if commit, let group = selectedGroup {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task {
            try await runLightSession(.menuBarButton, token) {
                let windowId = group.windows[safe: selectedWindowIndex]?.windowId ?? group.windows.first?.windowId
                if let windowId, let window = Window.get(byId: windowId) {
                    _ = window.focusWindow()
                }
            }
        }
    }
}

// MARK: - Data Model

struct AppGroupWindow: Identifiable {
    let id: UInt32 // windowId
    let windowId: UInt32
    let title: String
}

struct AppGroup: Identifiable {
    let id: Int32 // pid
    let pid: Int32
    let name: String
    let icon: NSImage
    let windows: [AppGroupWindow]
}

@MainActor
private func buildAppGroups() -> [AppGroup] {
    let workspace = focus.workspace
    let allWindows = workspace.allLeafWindowsRecursive

    var seenPids: [Int32] = []
    var windowsByPid: [Int32: [AppGroupWindow]] = [:]

    for window in allWindows {
        let pid = window.app.pid
        if windowsByPid[pid] == nil {
            seenPids.append(pid)
            windowsByPid[pid] = []
        }
        let title = window.app.name ?? "Window \(window.windowId)"
        windowsByPid[pid]?.append(AppGroupWindow(
            id: window.windowId,
            windowId: window.windowId,
            title: title,
        ))
    }

    return seenPids.compactMap { pid -> AppGroup? in
        guard let windows = windowsByPid[pid], !windows.isEmpty else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? "Unknown"
        let icon = app?.icon ?? NSImage(named: NSImage.applicationIconName)!
        return AppGroup(id: pid, pid: pid, name: name, icon: icon, windows: windows)
    }
}

// MARK: - Observable State

@MainActor
final class AppSwitcherState: ObservableObject {
    @Published var groups: [AppGroup]
    @Published var selectedAppIndex: Int
    @Published var selectedWindowIndex: Int = 0

    init(groups: [AppGroup], selectedAppIndex: Int) {
        self.groups = groups
        self.selectedAppIndex = selectedAppIndex
    }

    var selectedGroup: AppGroup? {
        groups[safe: selectedAppIndex]
    }

    func cycleApp(offset: Int) {
        guard !groups.isEmpty else { return }
        selectedAppIndex = (selectedAppIndex + offset + groups.count) % groups.count
        selectedWindowIndex = 0
    }

    func cycleWindow(offset: Int) {
        guard let group = selectedGroup, !group.windows.isEmpty else { return }
        selectedWindowIndex = (selectedWindowIndex + offset + group.windows.count) % group.windows.count
    }

    func refreshWindowTitles() async {
        var updatedGroups = groups
        for groupIndex in updatedGroups.indices {
            var updatedWindows = updatedGroups[groupIndex].windows
            for windowIndex in updatedWindows.indices {
                let windowId = updatedWindows[windowIndex].windowId
                if let window = Window.get(byId: windowId),
                   let realTitle = try? await window.title,
                   !realTitle.isEmpty
                {
                    updatedWindows[windowIndex] = AppGroupWindow(
                        id: updatedWindows[windowIndex].id,
                        windowId: windowId,
                        title: realTitle,
                    )
                }
            }
            updatedGroups[groupIndex] = AppGroup(
                id: updatedGroups[groupIndex].id,
                pid: updatedGroups[groupIndex].pid,
                name: updatedGroups[groupIndex].name,
                icon: updatedGroups[groupIndex].icon,
                windows: updatedWindows,
            )
        }
        groups = updatedGroups
    }
}

// MARK: - Panel

@MainActor
private final class AppSwitcherPanel: NSPanelHud {
    let contentState: AppSwitcherState
    private var localMonitor: Any?
    private var globalMonitor: Any?

    override var canBecomeKey: Bool { true }

    init(groups: [AppGroup], selectedAppIndex: Int) {
        self.contentState = AppSwitcherState(groups: groups, selectedAppIndex: selectedAppIndex)
        super.init()

        let content = AppSwitcherContent(state: contentState)
        let hosting = NSHostingView(rootView: content)
        self.contentView = hosting

        // Size the panel to fit content. Use a generous width; SwiftUI will intrinsic-size.
        let appCount = CGFloat(groups.count)
        let itemWidth: CGFloat = 88
        let padding: CGFloat = 32
        let panelWidth = max(200, min(appCount * itemWidth + padding * 2, 800))
        // Height: icons row (~110) + window list (~150) + padding
        let panelHeight: CGFloat = 300

        if let screen = NSScreen.main {
            let x = screen.frame.midX - panelWidth / 2
            let y = screen.frame.midY + screen.frame.height * 0.1 // upper third
            self.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    func show() {
        makeKeyAndOrderFront(nil)
        installEventMonitors()
    }

    override func close() {
        removeEventMonitors()
        super.close()
    }

    private func installEventMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleEvent(event) ? nil : event
        }
        // Global monitor for Cmd release when we don't have focus
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            _ = self.handleFlagsChanged(event)
        }
    }

    private func removeEventMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handleEvent(_ event: NSEvent) -> Bool {
        switch event.type {
            case .flagsChanged:
                return handleFlagsChanged(event)
            case .keyDown:
                return handleKeyDown(event)
            default:
                return false
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        // If Cmd key was released, commit selection
        if !event.modifierFlags.contains(.command) {
            Task { @MainActor in
                dismissAppSwitcher(commit: true)
            }
            return true
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let hasShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
            case 48: // Tab
                if hasShift {
                    contentState.cycleApp(offset: -1)
                } else {
                    contentState.cycleApp(offset: 1)
                }
                return true
            case 38: // j
                contentState.cycleWindow(offset: 1)
                return true
            case 40: // k
                contentState.cycleWindow(offset: -1)
                return true
            case 53: // Escape
                Task { @MainActor in
                    dismissAppSwitcher(commit: false)
                }
                return true
            default:
                return false
        }
    }
}

// MARK: - SwiftUI Views

private struct AppSwitcherContent: View {
    @ObservedObject var state: AppSwitcherState

    var body: some View {
        VStack(spacing: 0) {
            // App icons row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(state.groups.enumerated()), id: \.element.id) { index, group in
                            AppIconView(
                                group: group,
                                isSelected: index == state.selectedAppIndex,
                            )
                            .id(group.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: state.selectedAppIndex) { _ in
                    if let group = state.selectedGroup {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(group.id, anchor: .center)
                        }
                    }
                }
            }
            .background(.ultraThickMaterial)

            // Window list for selected app
            if let group = state.selectedGroup, group.windows.count > 1 {
                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                            WindowRow(
                                window: window,
                                isSelected: index == state.selectedWindowIndex,
                            )
                        }
                    }
                }
                .background(.ultraThinMaterial)
                .frame(maxHeight: 150)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 5)
    }
}

private struct AppIconView: View {
    let group: AppGroup
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: group.icon)
                    .resizable()
                    .frame(width: 64, height: 64)

                if group.windows.count > 1 {
                    Text("\(group.windows.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.secondary))
                        .offset(x: 4, y: -4)
                }
            }

            Text(group.name)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .frame(maxWidth: 72)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.6) : Color.clear),
        )
    }
}

private struct WindowRow: View {
    let window: AppGroupWindow
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: "macwindow")
                .frame(width: 20)
                .foregroundStyle(isSelected ? .white : .secondary)
            Text(window.title)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}
