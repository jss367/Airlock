@testable import AppBundle
import Foundation
import XCTest

final class QuickSwitcherTest: XCTestCase {
    @MainActor
    func testRepeatedPanelDismissalDoesNotRestoreStaleFocus() {
        setUpWorkspacesForTests()
        dismissQuickSwitcher(restoreFocus: false)
        dismissMissionControl(restoreFocus: false)
        let old = TestWindow.new(id: 501, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 502, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        external.nativeFocus()
        // Pause has already closed the panels. An older selection finishing later must be harmless.
        dismissQuickSwitcher()
        dismissMissionControl()
        XCTAssertTrue(TestApp.shared.focusedWindow === external)
    }

    func testWebSearchUrlKeepsQuerySyntaxCharacters() {
        for query in ["c++", "AT&T", "a=b", "50% off", "what is #1?"] {
            let url = webSearchUrl(query: query)
            let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .percentEncodedQueryItems?.first { $0.name == "q" }?.value?.removingPercentEncoding
            assertEquals(q, query)
        }
        assertEquals(webSearchUrl(query: "c++")?.absoluteString, "https://google.com/search?q=c%2B%2B")
    }

    @MainActor
    func testPausingReleasesHotkey() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = true
        registerQuickSwitcherHotkey()
        defer {
            sessionCoordinator.setEnabled(true)
            config.quickSwitcher.enabled = false
            registerQuickSwitcherHotkey()
        }
        assertEquals(isQuickSwitcherHotkeyRegistered, true)

        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isQuickSwitcherHotkeyRegistered, false)

        // Reloading config while paused must not re-register it
        registerQuickSwitcherHotkey()
        assertEquals(isQuickSwitcherHotkeyRegistered, false)

        _ = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isQuickSwitcherHotkeyRegistered, true)
    }

    @MainActor
    func testPanelsDontOpenWhilePaused() async throws {
        setUpWorkspacesForTests()
        defer { sessionCoordinator.setEnabled(true) }
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)

        toggleQuickSwitcher()
        assertEquals(isQuickSwitcherOpen, false)
        toggleMissionControl()
        assertEquals(isMissionControlOpen, false)
    }

    @MainActor
    func testAppLauncherDoesNotOpenWhilePaused() async throws {
        setUpWorkspacesForTests()
        defer { sessionCoordinator.setEnabled(true) }
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)

        showQuickSwitcher(scope: .apps)
        assertEquals(isQuickSwitcherOpen, false)
        XCTAssertNil(appLauncherPresentation)
    }

    // MARK: - Items

    @MainActor
    func testWindowsComeFirstMostRecentlyFocusedFirst() {
        setUpWorkspacesForTests()
        config.persistentWorkspaces = ["spare"] // Stays around without windows
        let first = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
        TestWindow.new(id: 3, parent: Workspace.get(byName: "b").rootTilingContainer)
        TestWindow.new(id: 4, parent: Workspace.get(byName: "a").rootTilingContainer)
        _ = Workspace.get(byName: "spare")
        XCTAssertTrue(second.focusWindow())
        XCTAssertTrue(first.focusWindow())

        let items = quickSwitcherTreeItems(titles: [:])
        // Focused windows by recency, then never-focused ones in tree order, then workspaces with windows
        assertEquals(rankSwitcherItems(items, query: "").map(\.id), ["win-1", "win-2", "win-4", "win-3", "ws-a", "ws-b"])
        // A workspace without windows is listed once the query finds it
        assertEquals(rankSwitcherItems(items, query: "spare").map(\.id), ["ws-spare"])
    }

    @MainActor
    func testWindowRowShowsTitleWithAppAndWorkspace() {
        setUpWorkspacesForTests()
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        TestWindow.new(id: 2, parent: Workspace.get(byName: "a").rootTilingContainer)
        let appName = TestApp.shared.name!

        let items = quickSwitcherTreeItems(titles: [1: "Inbox", 2: appName])
        let titled = items.first { $0.id == "win-1" }
        assertEquals(titled?.title, "Inbox")
        assertEquals(titled?.subtitle, "\(appName) · Workspace a")
        // A window titled after its app, or not read yet, shows the app name once
        let untitled = items.first { $0.id == "win-2" }
        assertEquals(untitled?.title, appName)
        assertEquals(untitled?.subtitle, "Workspace a")
    }

    // MARK: - Ranking

    private static func window(_ id: UInt32, _ title: String?, app: String, workspace: String = "1") -> SwitcherItem {
        .window(id: id, title: title, appName: app, workspaceName: workspace, iconPath: nil)
    }

    private static func app(_ name: String) -> SwitcherItem {
        .installedApp(InstalledAppInfo(name: name, bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/\(name).app")), subtitle: "Application")
    }

    func testWindowIsFoundByTitleAppAndWorkspace() {
        let items = [
            Self.window(1, "Pull requests", app: "Safari", workspace: "web"),
            Self.window(2, "Inbox", app: "Mail", workspace: "comms"),
        ]
        assertEquals(rankSwitcherItems(items, query: "pull").map(\.id), ["win-1"])
        assertEquals(rankSwitcherItems(items, query: "mail").map(\.id), ["win-2"])
        assertEquals(rankSwitcherItems(items, query: "comms").map(\.id), ["win-2"])
        // Every word must match, each in any field
        assertEquals(rankSwitcherItems(items, query: "saf pull").map(\.id), ["win-1"])
        assertEquals(rankSwitcherItems(items, query: "saf inbox").map(\.id), [])
    }

    func testEqualMatchesKeepTheirOrder() {
        // Three windows of one app differ only by recency, which is the order they come in
        let items = [3, 1, 2].map { Self.window($0, "Tab \($0)", app: "Safari") }
        assertEquals(rankSwitcherItems(items, query: "safari").map(\.id), ["win-3", "win-1", "win-2"])
    }

    func testBetterMatchRanksFirstWithinSection() {
        let items = [Self.app("Font Book"), Self.app("Books"), Self.app("Notes")]
        assertEquals(rankSwitcherItems(items, query: "boo").map(\.title), ["Books", "Font Book"])
    }

    func testSectionWithBestMatchComesFirst() {
        let items = [
            Self.window(1, "Release notes", app: "Safari"),
            SwitcherItem.workspace(name: "notes", appNames: ["Safari"], detail: "Empty"),
            Self.app("Notes"),
        ]
        // Without a query: windows, workspaces, apps
        assertEquals(rankSwitcherItems(items, query: "").map(\.section), [.windows, .workspaces, .apps])
        // "notes" starts the workspace and app names but not the window title. Workspaces come before apps on a tie
        assertEquals(rankSwitcherItems(items, query: "notes").map(\.section), [.workspaces, .apps, .windows])
    }

    func testWorkspaceIsFoundByItsAppsBelowTheirWindows() {
        let items = [
            SwitcherItem.workspace(name: "3", appNames: ["Mail", "Safari"], detail: "Empty"),
            Self.window(1, "Inbox", app: "Mail", workspace: "3"),
        ]
        assertEquals(rankSwitcherItems(items, query: "mail").map(\.id), ["win-1", "ws-3"])
    }

    // MARK: - Model

    @MainActor
    func testWebSearchIsTheFallbackOutsideTheAppsScope() {
        let all = QuickSwitcherModel(scope: .all, items: [Self.app("Notes")], pointerLocation: { .zero })
        all.query = " how to exit vim "
        assertEquals(all.rows.map(\.kind), [.webSearch(query: "how to exit vim")])
        all.query = "not"
        assertEquals(all.rows.map(\.title), ["Notes"])

        let apps = QuickSwitcherModel(scope: .apps, items: [Self.app("Notes")], pointerLocation: { .zero })
        apps.query = "how to exit vim"
        assertEquals(apps.rows.count, 0)
        assertEquals(apps.emptyMessage, "No matches for “how to exit vim”")
    }

    @MainActor
    func testWindowTitleArrivingLaterBecomesSearchable() {
        let model = QuickSwitcherModel(scope: .all, items: [Self.window(1, nil, app: "Safari"), Self.window(2, nil, app: "Safari")], pointerLocation: { .zero })
        assertEquals(model.rows.map(\.title), ["Safari", "Safari"])
        model.query = "invoice"
        assertEquals(model.rows.map(\.section), [.web])

        model.setTitle("Invoice 42", forWindow: 2)
        assertEquals(model.rows.map(\.id), ["win-2"])
        assertEquals(model.rows.first?.subtitle, "Safari · Workspace 1")
        assertEquals(model.windowIds, [1, 2])
    }

    @MainActor
    func testSelectionFollowsPickedRowWhileContentLoads() {
        let model = QuickSwitcherModel(scope: .all, items: [Self.window(1, nil, app: "Safari"), Self.app("Notes")], pointerLocation: { .zero })
        // Untouched, the selection stays on the top row
        model.setApps([Self.app("Books"), Self.app("Notes")])
        assertEquals(model.selectedItem?.id, "win-1")

        model.moveSelection(by: 2)
        assertEquals(model.selectedItem?.title, "Notes")
        model.setApps([Self.app("Books"), Self.app("Calendar"), Self.app("Notes")])
        assertEquals(model.selectedItem?.title, "Notes")
        // The picked row is gone: back to the top
        model.setApps([Self.app("Books")])
        assertEquals(model.selectedIndex, 0)

        model.moveSelection(by: 1)
        model.query = "b"
        assertEquals(model.selectedIndex, 0)
        model.moveSelection(by: -1)
        assertEquals(model.selectedIndex, 0)
        model.moveSelection(by: 10)
        assertEquals(model.selectedIndex, model.rows.count - 1)
    }

    @MainActor
    func testStationaryPointerKeepsPickedAppAfterDiscoveryReordersRows() {
        var pointer = CGPoint.zero
        let model = QuickSwitcherModel(scope: .apps, items: [Self.app("Books"), Self.app("Notes")], pointerLocation: { pointer })
        pointer.x = 10
        model.hover(at: 1)
        assertEquals(model.selectedItem?.title, "Notes")
        model.setApps([Self.app("Books"), Self.app("Calendar"), Self.app("Notes")])
        // New content moved under the pointer without any pointer movement.
        model.hover(at: 1)
        assertEquals(model.selectedItem?.title, "Notes")
        assertEquals(model.selectionCameFromKeyboard, false)
        pointer.x = 20
        model.hover(at: 1)
        assertEquals(model.selectedItem?.title, "Calendar")
    }

    @MainActor
    func testStationaryPointerKeepsPickedWindowAfterTitleReranksRows() {
        var pointer = CGPoint.zero
        let model = QuickSwitcherModel(scope: .all, items: [Self.window(1, "Build release", app: "Safari"), Self.window(2, "Release notes", app: "Safari")], pointerLocation: { pointer })
        model.query = "release"
        assertEquals(model.rows.map(\.id), ["win-2", "win-1"])
        pointer.x = 10
        model.hover(at: 1)
        model.setTitle("Release", forWindow: 1)
        assertEquals(model.rows.map(\.id), ["win-1", "win-2"])
        assertEquals(model.selectedItem?.id, "win-1")
        model.hover(at: 1)
        assertEquals(model.selectedItem?.id, "win-1")
    }

    @MainActor
    func testCancelledTitleReadCannotOverwriteReplacementPanelCache() async {
        var pending: CheckedContinuation<String?, Never>?
        var cache: [UInt32: String] = [:]
        let closed = QuickSwitcherModel(scope: .all, items: [Self.window(1, nil, app: "Safari")])
        let oldRead = Task {
            await loadQuickSwitcherTitle(windowId: 1, readTitle: { _ in
                await withCheckedContinuation { pending = $0 }
            }) { id, title in
                cache[id] = title
                closed.setTitle(title, forWindow: id)
            }
        }
        while pending == nil { await Task.yield() }
        oldRead.cancel()
        let reopened = QuickSwitcherModel(scope: .all, items: [Self.window(1, nil, app: "Safari")])
        await loadQuickSwitcherTitle(windowId: 1, readTitle: { _ in "Current title" }) { id, title in
            cache[id] = title
            reopened.setTitle(title, forWindow: id)
        }
        pending?.resume(returning: "Stale title")
        await oldRead.value
        assertEquals(cache[1], "Current title")
        assertEquals(reopened.selectedItem?.title, "Current title")
        assertEquals(closed.selectedItem?.title, "Safari")
    }

    @MainActor
    func testRestingPointerDoesNotOverrideKeyboard() {
        var pointer = CGPoint(x: 100, y: 100)
        let model = QuickSwitcherModel(scope: .apps, items: [Self.app("Books"), Self.app("Notes"), Self.app("Safari")], pointerLocation: { pointer })
        // The panel opened under the pointer
        model.hover(at: 2)
        assertEquals(model.selectedIndex, 0)

        pointer.x += 10
        model.hover(at: 2)
        assertEquals(model.selectedIndex, 2)
        assertEquals(model.selectionCameFromKeyboard, false)

        // Arrow keys and typing move rows under the pointer, which stays where it is
        model.moveSelection(by: -1)
        model.hover(at: 2)
        assertEquals(model.selectedIndex, 1)
        assertEquals(model.selectionCameFromKeyboard, true)
        pointer.y += 10
        model.hover(at: 2)
        assertEquals(model.selectedIndex, 2)
        model.query = "o"
        model.hover(at: 1)
        assertEquals(model.selectedIndex, 0)
    }

    // MARK: - Launcher

    @MainActor
    func testAppLauncherActionPrefersWindowOnWorkspace() {
        setUpWorkspacesForTests()
        let here = Workspace.get(byName: "here")
        let pids: Set<pid_t> = [TestApp.shared.pid]
        guard case .launch = appLauncherAction(runningPids: pids, workspace: here) else { return XCTFail("No windows: launch") }

        let elsewhere = TestWindow.new(id: 1, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        guard case .summon(let summoned) = appLauncherAction(runningPids: pids, workspace: here) else { return XCTFail("Window on another workspace: summon") }
        XCTAssertTrue(summoned === elsewhere)

        let local = TestWindow.new(id: 2, parent: here.rootTilingContainer)
        guard case .focus(let focused) = appLauncherAction(runningPids: pids, workspace: here) else { return XCTFail("Window on this workspace: focus") }
        XCTAssertTrue(focused === local)

        guard case .launch = appLauncherAction(runningPids: [], workspace: here) else { return XCTFail("Not running: launch") }
        guard case .launch = appLauncherAction(runningPids: [TestApp.shared.pid + 1], workspace: here) else { return XCTFail("Another app's windows don't count") }
    }

    @MainActor
    func testPausingClosesMissionControl() async throws {
        setUpWorkspacesForTests()
        defer {
            sessionCoordinator.setEnabled(true)
            dismissMissionControl(restoreFocus: false)
        }
        toggleMissionControl()
        assertEquals(isMissionControlOpen, true) // Still capturing thumbnails

        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isMissionControlOpen, false)
    }
}
