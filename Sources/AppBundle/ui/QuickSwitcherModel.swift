import AppKit
import Common

/// What the Quick Switcher panel lists
enum QuickSwitcherScope: Equatable {
    /// Windows, workspaces, and installed apps, with a web search when nothing matches
    case all
    /// Installed apps only. This is what the `app-launcher` command opens
    case apps

    var placeholder: String {
        switch self {
            case .all: "Search windows, workspaces, and apps, or the web"
            case .apps: "Search apps"
        }
    }
}

// MARK: - Items

enum SwitcherSection: Int, Comparable {
    case windows, workspaces, apps, web

    var title: String {
        switch self {
            case .windows: "Windows"
            case .workspaces: "Workspaces"
            case .apps: "Applications"
            case .web: "Web"
        }
    }

    static func < (lhs: SwitcherSection, rhs: SwitcherSection) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct SwitcherSearchField {
    let target: FuzzyTarget
    /// How much of a match in this field counts, in percent
    let weight: Int

    init(_ text: String, weight: Int = 100) {
        self.target = FuzzyTarget(text)
        self.weight = weight
    }
}

struct SwitcherItem: Identifiable {
    enum Kind: Hashable {
        case window(id: UInt32, appName: String, workspaceName: String)
        case workspace(name: String)
        case installedApp(url: URL, bundleIdentifier: String?)
        case webSearch(query: String)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    /// The file whose icon the row shows. Nil for a symbol that stands for the kind
    let iconPath: String?
    let searchFields: [SwitcherSearchField]
    /// False for entries that are listed only once the query finds them, like empty workspaces
    let isListedWithoutQuery: Bool

    var section: SwitcherSection {
        switch kind {
            case .window: .windows
            case .workspace: .workspaces
            case .installedApp: .apps
            case .webSearch: .web
        }
    }

    /// `title` is the window's own title, nil while it hasn't been read yet
    static func window(id: UInt32, title: String?, appName: String, workspaceName: String, iconPath: String?) -> SwitcherItem {
        // Many single-window apps title their window after themselves
        let title = title?.takeIf { !$0.isEmpty && $0 != appName }
        let workspace = "Workspace \(workspaceName)"
        return SwitcherItem(
            id: "win-\(id)",
            kind: .window(id: id, appName: appName, workspaceName: workspaceName),
            title: title ?? appName,
            subtitle: title == nil ? workspace : "\(appName) · \(workspace)",
            iconPath: iconPath,
            searchFields: [title.map { SwitcherSearchField($0) }, SwitcherSearchField(appName), SwitcherSearchField(workspaceName, weight: 50)]
                .compactMap(\.self),
            isListedWithoutQuery: true,
        )
    }

    /// `detail` describes a workspace without windows
    static func workspace(name: String, appNames: [String], detail: String) -> SwitcherItem {
        let apps = appNames.joined(separator: ", ")
        return SwitcherItem(
            id: "ws-\(name)",
            kind: .workspace(name: name),
            title: name,
            subtitle: appNames.isEmpty ? detail : apps,
            iconPath: nil,
            // A workspace is also found by what's on it, below the windows themselves
            searchFields: [SwitcherSearchField(name), SwitcherSearchField(apps, weight: 40)],
            isListedWithoutQuery: !appNames.isEmpty,
        )
    }

    static func installedApp(_ app: InstalledAppInfo, subtitle: String) -> SwitcherItem {
        SwitcherItem(
            id: "app-\(app.url.path)",
            kind: .installedApp(url: app.url, bundleIdentifier: app.bundleIdentifier),
            title: app.name,
            subtitle: subtitle,
            iconPath: app.url.path,
            searchFields: [SwitcherSearchField(app.name)],
            isListedWithoutQuery: true,
        )
    }

    static func webSearch(query: String) -> SwitcherItem {
        SwitcherItem(
            id: "web-search",
            kind: .webSearch(query: query),
            title: "Search Google for “\(query)”",
            subtitle: "Open in browser",
            iconPath: nil,
            searchFields: [],
            isListedWithoutQuery: false,
        )
    }

    /// Every word of the query must be found in one of the fields. Nil if one isn't
    fileprivate func matchScore(_ tokens: [[Character]]) -> Int? {
        var total = 0
        for token in tokens {
            var best: Int? = nil
            for field in searchFields {
                guard let score = fuzzyMatch(query: token, target: field.target) else { continue }
                best = max(best ?? 0, score * field.weight / 100)
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }
}

// MARK: - Ranking

/// The rows to show for `query`, in display order. `items` come in their order without a query:
/// that order breaks ties, so equally good matches keep, for example, windows by recency.
///
/// Rows stay grouped by section. The section with the best match comes first, so the best row
/// overall is always on top
func rankSwitcherItems(_ items: [SwitcherItem], query: String) -> [SwitcherItem] {
    let tokens = fuzzyQueryTokens(query)
    var sections: [SwitcherSection: [RankedItem]] = [:]
    for (index, item) in items.enumerated() {
        let score: Int? = tokens.isEmpty ? (item.isListedWithoutQuery ? 0 : nil) : item.matchScore(tokens)
        guard let score else { continue }
        sections[item.section, default: []].append(RankedItem(item: item, score: score, index: index))
    }
    var groups: [RankedSection] = []
    for (section, matches) in sections {
        let sorted = matches.sorted { (a: RankedItem, b: RankedItem) -> Bool in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        groups.append(RankedSection(section: section, best: sorted.first?.score ?? 0, matches: sorted))
    }
    groups.sort { (a: RankedSection, b: RankedSection) -> Bool in
        if a.best != b.best { return a.best > b.best }
        return a.section < b.section
    }
    return groups.flatMap { $0.matches.map(\.item) }
}

private struct RankedSection {
    let section: SwitcherSection
    let best: Int
    let matches: [RankedItem]
}

private struct RankedItem {
    let item: SwitcherItem
    let score: Int
    let index: Int
}

// MARK: - Model

struct SwitcherRowGroup: Identifiable {
    let section: SwitcherSection
    /// Rows with their index in `QuickSwitcherModel.rows`
    var rows: [(index: Int, item: SwitcherItem)]
    var id: SwitcherSection { section }
}

@MainActor
final class QuickSwitcherModel: ObservableObject {
    let scope: QuickSwitcherScope
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Typing moves rows under a resting pointer, which must not select them
            markKeyboardSelection()
            selectionWasMoved = false
            refreshRows()
        }
    }
    @Published private(set) var rows: [SwitcherItem] = []
    @Published private(set) var selectedIndex = 0
    /// True during the first scan for installed apps, when there is no earlier list to show yet
    @Published var isLoadingApps = false

    private var items: [SwitcherItem]
    /// Until the user picks a row, the selection stays on the best match while titles and apps load
    private var selectionWasMoved = false

    /// Reads the pointer position in screen coordinates
    private let pointerLocation: @MainActor () -> CGPoint
    /// Where the pointer was at the last keyboard selection. Hovering only selects once the pointer has
    /// moved away from here, so a pointer resting where the panel opens, or over rows that change
    /// while typing, doesn't override the keyboard
    private var pointerAnchor: CGPoint
    /// The list scrolls to keyboard selections only. Scrolling to a hovered row would move it out
    /// from under the pointer and select its neighbor
    private(set) var selectionCameFromKeyboard = true

    init(
        scope: QuickSwitcherScope,
        items: [SwitcherItem] = [],
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
    ) {
        self.scope = scope
        self.items = items
        self.pointerLocation = pointerLocation
        self.pointerAnchor = pointerLocation()
        refreshRows()
    }

    var selectedItem: SwitcherItem? { rows[safe: selectedIndex] }

    var rowGroups: [SwitcherRowGroup] {
        var groups: [SwitcherRowGroup] = []
        for (index, item) in rows.enumerated() {
            if groups.last?.section == item.section {
                groups[groups.count - 1].rows.append((index, item))
            } else {
                groups.append(SwitcherRowGroup(section: item.section, rows: [(index, item)]))
            }
        }
        return groups
    }

    /// What to say when there are no rows
    var emptyMessage: String {
        let query = query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return "No matches for “\(query)”" }
        if isLoadingApps { return "Loading apps…" }
        return switch scope {
            case .all: "No windows, workspaces, or apps to show"
            case .apps: "No apps found"
        }
    }

    var windowIds: [UInt32] {
        items.compactMap { if case .window(let id, _, _) = $0.kind { id } else { nil } }
    }

    // MARK: Content

    /// The window's real title arrived. It replaces the app name as the row title and becomes searchable
    func setTitle(_ title: String, forWindow windowId: UInt32) {
        guard let index = items.firstIndex(where: { $0.id == "win-\(windowId)" }),
              case .window(_, let appName, let workspaceName) = items[index].kind
        else { return }
        let item = SwitcherItem.window(id: windowId, title: title, appName: appName, workspaceName: workspaceName, iconPath: items[index].iconPath)
        guard item.title != items[index].title else { return }
        items[index] = item
        refreshRows()
    }

    /// Replace the installed apps, which are discovered after the panel is already open
    func setApps(_ apps: [SwitcherItem]) {
        items.removeAll { $0.section == .apps }
        items.append(contentsOf: apps)
        refreshRows()
    }

    private func refreshRows() {
        let selectedId = selectionWasMoved ? selectedItem?.id : nil
        var rows = rankSwitcherItems(items, query: query)
        let query = query.trimmingCharacters(in: .whitespaces)
        if rows.isEmpty && !query.isEmpty && scope == .all {
            rows = [.webSearch(query: query)]
        }
        self.rows = rows
        let index = selectedId.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        if index != selectedIndex { selectedIndex = index }
    }

    // MARK: Keyboard

    func moveSelection(by offset: Int) {
        markKeyboardSelection()
        guard !rows.isEmpty else { return }
        let index = max(0, min(selectedIndex + offset, rows.count - 1))
        selectionWasMoved = true
        if index != selectedIndex { selectedIndex = index }
    }

    private func markKeyboardSelection() {
        selectionCameFromKeyboard = true
        pointerAnchor = pointerLocation()
    }

    // MARK: Pointer

    func hover(at index: Int) {
        if pointerHasMoved { select(at: index) }
    }

    func select(at index: Int) {
        guard rows.indices.contains(index), index != selectedIndex else { return }
        selectionCameFromKeyboard = false
        selectionWasMoved = true
        selectedIndex = index
    }

    private var pointerHasMoved: Bool {
        let location = pointerLocation()
        return hypot(location.x - pointerAnchor.x, location.y - pointerAnchor.y) > 2
    }
}

// MARK: - Building items

/// Windows first, most recently focused first, then workspaces. A workspace without windows is
/// listed only when the query finds it. `titles` holds the window titles read so far
@MainActor
func quickSwitcherTreeItems(titles: [UInt32: String]) -> [SwitcherItem] {
    let workspaces = workspacesForUi()
    let windows = workspaces
        .flatMap { workspace in workspace.allLeafWindowsRecursive.map { (window: $0, workspace: workspace) } }
        .enumerated()
        // Never-focused windows come last, in tree order
        .sorted { a, b in
            a.element.window.focusRecency != b.element.window.focusRecency
                ? a.element.window.focusRecency > b.element.window.focusRecency
                : a.offset < b.offset
        }
        .map(\.element)

    let windowItems = windows.map { window, workspace in
        SwitcherItem.window(
            id: window.windowId,
            title: titles[window.windowId],
            appName: window.app.name?.takeIf { !$0.isEmpty } ?? "Unknown",
            workspaceName: workspace.name,
            iconPath: window.app.bundlePath,
        )
    }
    let workspaceItems = workspaces.map { workspace in
        SwitcherItem.workspace(
            name: workspace.name,
            appNames: workspace.allLeafWindowsRecursive.compactMap { $0.app.name?.takeIf { !$0.isEmpty } }.toSet().sorted(),
            detail: workspace.isVisible ? "Empty, on \(workspace.workspaceMonitor.name)" : "Empty",
        )
    }
    return windowItems + workspaceItems
}

/// Rows for installed apps. Each says what selecting it does, see `appLauncherAction`. The `all`
/// scope leaves out apps whose windows it already lists: their window rows cover them
@MainActor
func quickSwitcherAppItems(_ apps: [InstalledAppInfo], scope: QuickSwitcherScope) -> [SwitcherItem] {
    var pidsByBundleId: [String: Set<pid_t>] = [:]
    for app in MacApp.allAppsMap.values {
        if let bundleId = app.rawAppBundleId { pidsByBundleId[bundleId, default: []].insert(app.pid) }
    }
    let listedPids: Set<pid_t> = scope == .all
        ? workspacesForUi().flatMap { $0.allLeafWindowsRecursive.map(\.app.pid) }.toSet()
        : []
    let workspace = focus.workspace
    return apps.compactMap { app in
        let pids = app.bundleIdentifier.flatMap { pidsByBundleId[$0] } ?? []
        guard pids.isDisjoint(with: listedPids) else { return nil }
        let subtitle = switch appLauncherAction(runningPids: pids, workspace: workspace) {
            case .focus: "Open on this workspace"
            case .summon(let window): window.nodeWorkspace.map { "Bring here from workspace \($0.name)" } ?? "Bring to this workspace"
            case .launch: pids.isEmpty ? "Application" : "Running"
        }
        return .installedApp(app, subtitle: subtitle)
    }
}
