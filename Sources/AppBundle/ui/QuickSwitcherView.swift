import AppKit
import Common
import HotKey
import SwiftUI

@MainActor private var quickSwitcherPanel: QuickSwitcherPanel?
@MainActor private var quickSwitcherHotkey: HotKey?
/// The last title read for each window. Reading titles is async, so without this every open
/// would show app names first and swap in the real titles a moment later
@MainActor private var quickSwitcherTitleCache: [UInt32: String] = [:]
/// The installed apps found by the last scan, listed right away the next time the panel opens
@MainActor private var quickSwitcherAppCache: [InstalledAppInfo] = []
@MainActor private var quickSwitcherIconCache: [String: NSImage] = [:]

@MainActor
func registerQuickSwitcherHotkey() {
    quickSwitcherHotkey?.isEnabled = false
    quickSwitcherHotkey = nil

    // Paused Airlock owns no hotkeys. EnableCommand calls this again on resume
    guard config.quickSwitcher.enabled && sessionCoordinator.isEnabled else { return }

    let parsed = parseBinding(config.quickSwitcher.binding, .emptyRoot, config.keyMapping.resolve())
    guard case .success(let (modifiers, key)) = parsed else { return }

    quickSwitcherHotkey = HotKey(key: key, modifiers: modifiers, keyDownHandler: {
        Task { @MainActor in
            toggleQuickSwitcher()
        }
    })
}

@MainActor var isQuickSwitcherHotkeyRegistered: Bool { quickSwitcherHotkey != nil }
@MainActor var isQuickSwitcherOpen: Bool { quickSwitcherPanel?.isVisible == true }

@MainActor
func toggleQuickSwitcher() {
    if let panel = quickSwitcherPanel, panel.isVisible {
        dismissQuickSwitcher()
    } else {
        showQuickSwitcher(scope: .all)
    }
}

/// Open the panel in `scope`, replacing a panel that is open in another scope
@MainActor
func showQuickSwitcher(scope: QuickSwitcherScope) {
    // Paused Airlock can't act on a selection, and pausing closes the panel. Stay closed
    guard sessionCoordinator.isEnabled else { return }
    if let panel = quickSwitcherPanel, panel.isVisible {
        if panel.model.scope == scope { return }
        dismissQuickSwitcher(restoreFocus: false)
    }
    quickSwitcherTitleCache = quickSwitcherTitleCache.filter { Window.get(byId: $0.key) != nil }
    let panel = QuickSwitcherPanel(scope: scope)
    quickSwitcherPanel = panel
    if scope == .apps { appLauncherPresentation = panel }
    panel.show()
}

/// Pass `restoreFocus: false` when another app is about to take focus (launch, web search).
/// Otherwise the panel activated Airlock, and nothing else hands focus back to a real window.
@MainActor
func dismissQuickSwitcher(restoreFocus: Bool = true) {
    // Clear the global before closing: close() resigns key, and resignKey dismisses only the current panel
    guard let panel = quickSwitcherPanel else { return }
    quickSwitcherPanel = nil
    if appLauncherPresentation === panel { appLauncherPresentation = nil }
    panel.close()
    if restoreFocus {
        focus.windowOrNil?.nativeFocus()
    }
}

private final class QuickSwitcherPanel: NSPanelHud, AppLauncherPresentation {
    let model: QuickSwitcherModel
    private var hostingView: NSHostingView<QuickSwitcherContent>?
    private let keyMonitor = PanelKeyMonitor()
    private var detailTasks: [Task<Void, Never>] = []

    override var canBecomeKey: Bool { true }

    init(scope: QuickSwitcherScope) {
        let treeItems = scope == .all ? quickSwitcherTreeItems(titles: quickSwitcherTitleCache) : []
        model = QuickSwitcherModel(scope: scope, items: treeItems + quickSwitcherAppItems(quickSwitcherAppCache, scope: scope))
        super.init()
        let content = QuickSwitcherContent(model: model, onActivate: { [weak self] in self?.activate($0) })
        let hosting = NSHostingView(rootView: content)
        self.contentView = hosting
        self.hostingView = hosting

        let size = CGSize(width: 620, height: 420)
        if let screen = NSScreen.main {
            let x = screen.frame.midX - size.width / 2
            // A little above the middle of the screen, without running off the top
            let y = min(screen.frame.midY - size.height / 2 + 100, screen.visibleFrame.maxY - size.height)
            self.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        }

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    override func close() {
        keyMonitor.remove()
        detailTasks.forEach { $0.cancel() }
        detailTasks = []
        super.close()
    }

    override func resignKey() {
        super.resignKey()
        // The user moved focus elsewhere on purpose, so don't pull it back to Airlock's focused window
        if quickSwitcherPanel === self { dismissQuickSwitcher(restoreFocus: false) }
    }

    /*conforms*/ func dismiss(restoreFocus: Bool) {
        if quickSwitcherPanel === self { dismissQuickSwitcher(restoreFocus: restoreFocus) }
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor.install { [weak self] in self?.handleKeyEvent($0) ?? false }
        loadDetails()
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

    /// Fill in real window titles and the installed apps after the panel is already on screen
    private func loadDetails() {
        // One task per window: an app that is slow to answer must not hold up the other titles
        for windowId in model.windowIds {
            detailTasks.append(Task { [model] in
                guard let window = Window.get(byId: windowId),
                      let title = try? await window.title,
                      !title.isEmpty
                else { return }
                quickSwitcherTitleCache[windowId] = title
                model.setTitle(title, forWindow: windowId)
            })
        }
        model.isLoadingApps = quickSwitcherAppCache.isEmpty
        detailTasks.append(Task { [model] in
            let installed = await discoverInstalledAppInfo()
            model.isLoadingApps = false
            // A canceled scan stops early with a partial list
            guard !Task.isCancelled, installed != quickSwitcherAppCache else { return }
            quickSwitcherAppCache = installed
            model.setApps(quickSwitcherAppItems(installed, scope: model.scope))
        })
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // An input method composing text needs the arrows, Return, and Escape for itself
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        switch event.keyCode {
            case 125: // Down arrow
                moveSelection(by: 1)
                return true
            case 126: // Up arrow
                moveSelection(by: -1)
                return true
            case 36, 76: // Return, Enter
                if let item = model.selectedItem { activate(item) }
                return true
            case 53: // Escape
                Task { @MainActor in dismissQuickSwitcher() }
                return true
            default:
                return false
        }
    }

    private func moveSelection(by offset: Int) {
        let previous = model.selectedIndex
        model.moveSelection(by: offset)
        // Keyboard focus stays in the search field, so VoiceOver has to be told about the selected row
        guard model.selectedIndex != previous, NSWorkspace.shared.isVoiceOverEnabled, let item = model.selectedItem else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "\(item.title), \(item.subtitle)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func activate(_ item: SwitcherItem) {
        switch item.kind {
            case .installedApp(let url, let bundleIdentifier):
                openAppFromLauncher(url: url, bundleIdentifier: bundleIdentifier) { dismiss(restoreFocus: $0) }
            case .webSearch(let query):
                if let url = webSearchUrl(query: query) {
                    NSWorkspace.shared.open(url)
                }
                dismiss(restoreFocus: false)
            case .workspace, .window:
                guard let token: RunSessionGuard = .isServerEnabled else {
                    // Airlock's focus is stale while paused, so don't send the user back to it
                    dismiss(restoreFocus: false)
                    return
                }
                Task {
                    do {
                        try await runLightSession(.menuBarButton, token) {
                            switch item.kind {
                                case .workspace(let name):
                                    focusWorkspaceFromUi(Workspace.get(byName: name))
                                case .window(let id, _, _):
                                    if let window = Window.get(byId: id) {
                                        focusWindowFromUi(window)
                                    }
                                default:
                                    break
                            }
                        }
                    } catch is CancellationError {
                        dismiss(restoreFocus: false)
                        return
                    } catch {
                        reportAppError(error, operation: "Selecting an item in Quick Switcher", userMessage: "Airlock could not switch to the selected item.")
                    }
                    dismiss(restoreFocus: true)
                }
        }
    }
}

func webSearchUrl(query: String) -> URL? {
    // .urlQueryAllowed leaves &, + and = as is, so "c++" would search "c" and "AT&T" would search "AT"
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=")
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "https://google.com/search?q=\(encoded)")
}

// MARK: - SwiftUI Views

struct QuickSwitcherContent: View {
    @ObservedObject var model: QuickSwitcherModel
    let onActivate: @MainActor (SwitcherItem) -> Void
    @FocusState private var isFocused: Bool

    private static let topId = "top"

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(model.scope.placeholder, text: $model.query)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .onSubmit {
                        if let item = model.selectedItem { onActivate(item) }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if model.rows.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
        .onAppear { isFocused = true }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topId)
                    ForEach(model.rowGroups) { group in
                        HStack {
                            Text(group.section.title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                        ForEach(group.rows, id: \.item.id) { index, item in
                            SwitcherRow(item: item, isSelected: index == model.selectedIndex)
                                .id(item.id)
                                .onContinuousHover { phase in
                                    if case .active = phase { model.hover(at: index) }
                                }
                                .onTapGesture {
                                    model.select(at: index)
                                    onActivate(item)
                                }
                                .accessibilityAction { onActivate(item) }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: model.selectedIndex) { _, index in
                guard model.selectionCameFromKeyboard else { return }
                if index == 0 {
                    // Back to the very top, so the first section's header is on screen too
                    proxy.scrollTo(Self.topId, anchor: .top)
                } else if let item = model.selectedItem {
                    proxy.scrollTo(item.id)
                }
            }
            .onChange(of: model.query) {
                proxy.scrollTo(Self.topId, anchor: .top)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(model.emptyMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SwitcherRow: View {
    let item: SwitcherItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let path = item.iconPath {
                Image(nsImage: quickSwitcherIcon(forFile: path))
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var symbolName: String {
        switch item.kind {
            case .workspace: "square.grid.2x2"
            case .window: "macwindow"
            case .installedApp: "app.badge"
            case .webSearch: "magnifyingglass"
        }
    }
}

/// Rows are drawn again on every keystroke, so each file's icon is looked up once
@MainActor
private func quickSwitcherIcon(forFile path: String) -> NSImage {
    if let icon = quickSwitcherIconCache[path] { return icon }
    let icon = NSWorkspace.shared.icon(forFile: path)
    quickSwitcherIconCache[path] = icon
    return icon
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
