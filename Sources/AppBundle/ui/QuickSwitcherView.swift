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

private final class QuickSwitcherPanel: NSPanelHud {
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
    let icon: NSImage?

    enum Kind: Hashable {
        case workspace(name: String)
        case window(id: UInt32)
        case installedApp(url: URL)
        case webSearch(query: String)
    }

    var sectionTitle: String {
        switch kind {
            case .workspace: return "Workspaces"
            case .window: return "Windows"
            case .installedApp: return "Applications"
            case .webSearch: return "Web"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SwitcherItem, rhs: SwitcherItem) -> Bool {
        lhs.id == rhs.id
    }
}

private struct IndexedItem {
    let index: Int
    let item: SwitcherItem
}

struct QuickSwitcherContent: View {
    @State private var query: String = ""
    @State private var items: [SwitcherItem] = []
    @State private var selectedIndex: Int = 0
    @State private var keyMonitor: Any?
    @State private var discoveryTask: Task<Void, Never>?
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
                kind: .webSearch(query: query),
                icon: nil,
            )]
        }
        return base
    }

    private var groupedItems: [(String, [IndexedItem])] {
        var sections: [(String, [IndexedItem])] = []
        var currentSection: String?
        var currentItems: [IndexedItem] = []

        for (index, item) in filteredItems.enumerated() {
            let section = item.sectionTitle
            if section != currentSection {
                if let current = currentSection {
                    sections.append((current, currentItems))
                }
                currentSection = section
                currentItems = []
            }
            currentItems.append(IndexedItem(index: index, item: item))
        }
        if let current = currentSection {
            sections.append((current, currentItems))
        }
        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                TextField("Search workspaces and windows...", text: $query)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .onSubmit { activateSelected() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThickMaterial)

            Divider()

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedItems, id: \.0) { sectionTitle, sectionItems in
                            // Section header
                            HStack {
                                Text(sectionTitle.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                            ForEach(sectionItems, id: \.item.id) { indexed in
                                SwitcherRow(item: indexed.item, isSelected: indexed.index == selectedIndex)
                                    .id(indexed.item.id)
                                    .onTapGesture {
                                        selectedIndex = indexed.index
                                        activateSelected()
                                    }
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
            .background(.ultraThickMaterial)
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
            discoveryTask?.cancel()
            discoveryTask = nil
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
                kind: .workspace(name: ws.name),
                icon: nil,
            ))
        }

        // Add individual windows
        for ws in workspaces {
            for window in ws.allLeafWindowsRecursive {
                let appName = window.app.name ?? "Unknown"
                let icon = (window.app as? MacApp).flatMap { $0.bundlePath }.map { NSWorkspace.shared.icon(forFile: $0) }
                result.append(SwitcherItem(
                    id: "win-\(window.windowId)",
                    title: appName,
                    subtitle: "on \(ws.name)",
                    kind: .window(id: window.windowId),
                    icon: icon,
                ))
            }
        }

        items = result

        // Discover installed apps on a background thread to avoid blocking the UI
        discoveryTask = Task {
            let runningBundleIds = await MainActor.run {
                Set(MacApp.allAppsMap.values.compactMap { $0.rawAppBundleId })
            }
            let installed = await discoverInstalledAppInfo()
            guard !Task.isCancelled else { return }
            let appItems = installed.compactMap { app -> SwitcherItem? in
                if let bundleId = app.bundleIdentifier, runningBundleIds.contains(bundleId) {
                    return nil
                }
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                return SwitcherItem(
                    id: "app-\(app.url.path)",
                    title: app.name,
                    subtitle: "Launch application",
                    kind: .installedApp(url: app.url),
                    icon: icon,
                )
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                items.append(contentsOf: appItems)
            }
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
                   let url = URL(string: "https://google.com/search?q=\(encoded)")
                {
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
        HStack(spacing: 10) {
            if let nsIcon = item.icon {
                Image(nsImage: nsIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
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
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 6),
        )
        .contentShape(Rectangle())
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
