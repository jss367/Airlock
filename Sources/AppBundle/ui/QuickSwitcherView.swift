import AppKit
import Common
import HotKey
import SwiftUI

@MainActor private var quickSwitcherPanel: QuickSwitcherPanel?
@MainActor private var quickSwitcherHotkey: HotKey?

@MainActor
func registerQuickSwitcherHotkey() {
    quickSwitcherHotkey = HotKey(key: .space, modifiers: [.option], keyDownHandler: {
        Task { @MainActor in
            toggleQuickSwitcher()
        }
    })
}

@MainActor
func toggleQuickSwitcher() {
    if let panel = quickSwitcherPanel, panel.isVisible {
        panel.close()
        quickSwitcherPanel = nil
    } else {
        let panel = QuickSwitcherPanel()
        quickSwitcherPanel = panel
        panel.show()
    }
}

@MainActor
func dismissQuickSwitcher() {
    quickSwitcherPanel?.close()
    quickSwitcherPanel = nil
}

private class QuickSwitcherPanel: NSPanelHud {
    private var hostingView: NSHostingView<QuickSwitcherContent>?

    override var canBecomeKey: Bool { true }

    override init() {
        super.init()
        let content = QuickSwitcherContent()
        let hosting = NSHostingView(rootView: content)
        self.contentView = hosting
        self.hostingView = hosting

        let width: CGFloat = 500
        let height: CGFloat = 350
        if let screen = NSScreen.main {
            let x = screen.frame.midX - width / 2
            let y = screen.frame.midY - height / 2 + 100
            self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI @FocusState doesn't reliably focus fields in NSPanel.
        // Explicitly walk the view hierarchy to find and focus the text field.
        DispatchQueue.main.async { [weak self] in
            guard let self, let hosting = self.hostingView else { return }
            if let textField = self.findTextField(in: hosting) {
                self.makeFirstResponder(textField)
            }
        }
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField, tf.isEditable { return tf }
        for sub in view.subviews {
            if let found = findTextField(in: sub) { return found }
        }
        return nil
    }
}

struct SwitcherItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind

    enum Kind: Hashable {
        case workspace(name: String)
        case window(id: UInt32)
        case installedApp(url: URL)
        case webSearch(query: String)
    }
}

struct QuickSwitcherContent: View {
    @State private var query: String = ""
    @State private var items: [SwitcherItem] = []
    @State private var selectedIndex: Int = 0
    @State private var keyMonitor: Any?
    @FocusState private var isFocused: Bool

    var filteredItems: [SwitcherItem] {
        let base: [SwitcherItem]
        if query.isEmpty {
            base = items
        } else {
            let q = query.lowercased()
            base = items.filter {
                $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
            }
        }
        if base.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return [SwitcherItem(
                id: "web-search",
                title: "Search Google for '\(query)'",
                subtitle: "Open in browser",
                kind: .webSearch(query: query)
            )]
        }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search workspaces and windows...", text: $query)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .onSubmit { activateSelected() }
            }
            .padding(12)
            .background(.ultraThickMaterial)

            Divider()

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            SwitcherRow(item: item, isSelected: index == selectedIndex)
                                .id(item.id)
                                .onTapGesture {
                                    selectedIndex = index
                                    activateSelected()
                                }
                        }
                    }
                }
                .onChange(of: selectedIndex) { newIndex in
                    if let item = filteredItems[safe: newIndex] {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
        .onAppear {
            loadItems()
            isFocused = true
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                return handleKeyEvent(event) ? nil : event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .onChange(of: query) { _ in
            selectedIndex = 0
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: // Down arrow
            if selectedIndex < filteredItems.count - 1 { selectedIndex += 1 }
            return true
        case 126: // Up arrow
            if selectedIndex > 0 { selectedIndex -= 1 }
            return true
        case 36: // Return
            activateSelected()
            return true
        case 53: // Escape
            Task { @MainActor in dismissQuickSwitcher() }
            return true
        default:
            return false
        }
    }

    @MainActor
    private func loadItems() {
        var result: [SwitcherItem] = []

        // Add workspaces
        let persistentOrder = config.persistentWorkspaces
        let workspaces = Workspace.all.sorted { a, b in
            let ai = persistentOrder.firstIndex(of: a.name)
            let bi = persistentOrder.firstIndex(of: b.name)
            switch (ai, bi) {
            case (.some(let ai), .some(let bi)): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a < b
            }
        }

        for ws in workspaces {
            let apps = ws.allLeafWindowsRecursive
                .compactMap { $0.app.name?.takeIf { !$0.isEmpty } }
                .toSet()
                .sorted()
                .joined(separator: ", ")
            let subtitle = apps.isEmpty ? (ws.isVisible ? ws.workspaceMonitor.name : "empty") : apps
            result.append(SwitcherItem(
                id: "ws-\(ws.name)",
                title: ws.name,
                subtitle: subtitle,
                kind: .workspace(name: ws.name)
            ))
        }

        // Add individual windows
        for ws in workspaces {
            for window in ws.allLeafWindowsRecursive {
                let appName = window.app.name ?? "Unknown"
                result.append(SwitcherItem(
                    id: "win-\(window.windowId)",
                    title: appName,
                    subtitle: "on \(ws.name)",
                    kind: .window(id: window.windowId)
                ))
            }
        }

        items = result

        // Load installed apps asynchronously so the panel appears instantly
        Task { @MainActor in
            let runningBundleIds = Set(MacApp.allAppsMap.values.compactMap { $0.rawAppBundleId })
            var appItems: [SwitcherItem] = []
            for app in discoverInstalledApps() {
                if let bundleId = app.bundleIdentifier, runningBundleIds.contains(bundleId) {
                    continue
                }
                appItems.append(SwitcherItem(
                    id: "app-\(app.url.path)",
                    title: app.name,
                    subtitle: "Launch application",
                    kind: .installedApp(url: app.url)
                ))
            }
            items.append(contentsOf: appItems)
        }
    }

    @MainActor
    private func activateSelected() {
        guard let item = filteredItems[safe: selectedIndex] else { return }

        switch item.kind {
        case .installedApp(let url):
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            dismissQuickSwitcher()
        case .webSearch(let query):
            if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://google.com/search?q=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
            dismissQuickSwitcher()
        case .workspace, .window:
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            Task {
                try await runLightSession(.menuBarButton, token) {
                    switch item.kind {
                    case .workspace(let name):
                        _ = Workspace.get(byName: name).focusWorkspace()
                    case .window(let id):
                        if let window = Window.get(byId: id) {
                            _ = window.focusWindow()
                        }
                    default:
                        break
                    }
                }
                dismissQuickSwitcher()
            }
        }
    }
}

private struct SwitcherRow: View {
    let item: SwitcherItem
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .frame(width: 24)
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
    }

    private var iconName: String {
        switch item.kind {
        case .workspace: return "square.grid.2x2"
        case .window: return "macwindow"
        case .installedApp: return "app.badge"
        case .webSearch: return "magnifyingglass"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
