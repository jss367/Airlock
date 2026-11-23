@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class SettingsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // MARK: - Requirements

    func testFeaturesThatNeedWindowManagementSayWhyTheyAreDisabled() {
        config.enableWindowManagement = false

        let disabled = (behaviorFeatures + appFeatures).filter { unmetReason($0.requirement, config) != nil }.map(\.key)

        assertEquals(disabled, ["tile-new-windows", "enable-workspace-app-switching", "focus-workspace-on-mouse-click"])
        assertEquals(unmetReason(.windowManagement, config), "Requires Window management, which is off.")
        assertNotNil(unmetReason(preventFocusStealingRequirement, config))
    }

    func testAppSwitchingScopeNamesTheFirstSettingToTurnOn() {
        assertNil(unmetReason(.workspaceAppSwitching, config))

        config.enableWorkspaceAppSwitching = false
        assertEquals(unmetReason(.workspaceAppSwitching, config), "Requires Workspace app switching, which is off.")

        // Turning on Workspace app switching alone wouldn't help, so the reason names Window management
        config.enableWindowManagement = false
        assertEquals(unmetReason(.workspaceAppSwitching, config), "Requires Window management, which is off.")
    }

    func testNothingIsDisabledWithDefaults() {
        assertEquals((behaviorFeatures + appFeatures).filter { unmetReason($0.requirement, config) != nil }.map(\.key), [])
        assertNil(unmetReason(preventFocusStealingRequirement, config))
        assertNil(unmetReason(.focusFlash, config))
        assertNil(unmetReason(nil, config))
    }

    func testFocusFlashRequirement() {
        config.focusFlash.enabled = false

        assertNotNil(unmetReason(.focusFlash, config))
    }

    /// The switch is disabled for the reason the bindings are: `activeBindings` drops them
    func testAppSwitchingRequirementMatchesTheBindings() {
        let bindings = Dictionary(uniqueKeysWithValues: parseBindings("cmd-tab = 'focus app-next'").map { ($0.descriptionWithKeyCode, $0) })
        config.enableWindowManagement = false
        config.enableWorkspaceAppSwitching = true

        assertEquals(activeBindings(bindings, config).count, 0)
        assertNotNil(unmetReason(behaviorFeatures.first { $0.key == "enable-workspace-app-switching" }?.requirement, config))
    }

    // MARK: - Menu bar style

    func testMenuBarStyleDefaultsToOccupiedWorkspaces() {
        assertEquals(ExperimentalUISettings.displayStyle(storedValue: nil), .i3Ordered)
        assertEquals(ExperimentalUISettings.displayStyle(storedValue: "not a style"), .i3Ordered)
    }

    func testStoredMenuBarStyleIsRespected() {
        for style in MenuBarStyle.allCases {
            assertEquals(ExperimentalUISettings.displayStyle(storedValue: style.rawValue), style)
        }
    }

    // MARK: - Focus flash color

    func testColorIsWrittenTheWayTheConfigParsesIt() {
        for value in ["0xff00ff00", "0x80ff0000", "0x00000000", "0xffffffff", "0x12345678"] {
            assertEquals(parseAARRGGBB(value).flatMap(aarrggbbString), value)
        }
        assertEquals(parseAARRGGBB("0XFF00FF00").flatMap(aarrggbbString), "0xff00ff00")
    }

    func testWrittenColorIsAcceptedByTheConfig() {
        let value = aarrggbbString(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)) ?? ""
        let (parsed, errors) = parseConfig("[focus-flash]\ncolor = '\(value)'")

        assertEquals(errors.descriptions, [])
        assertEquals(parsed.focusFlash.color, "0xcc336699")
    }

    func testClosingOrLeavingAppearanceFlushesTheLatestRapidEditOnce() async {
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(wait: { try await Task.sleep(for: .seconds(30)) }, write: { writes.append($0) })
        edit.set(2, saved: 1)
        edit.set(3, saved: 1)
        await edit.flush()?.value // The view's onDisappear, before the debounce elapsed.
        await edit.flush()?.value // Closing the window after changing tabs must not write twice.
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(writes, [3])
        edit.synchronize(saved: 3)
        assertNil(edit.draft)
    }

    func testCanceledDebounceCannotWriteAgainAfterTeardown() async {
        var resume: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(wait: { await withCheckedContinuation { resume = $0 } }, write: { writes.append($0) })
        edit.set(2, saved: 1)
        while resume == nil { await Task.yield() }
        await edit.flush()?.value
        resume?.resume()
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(writes, [2])
    }

    func testCompletedDebounceIsNotWrittenAgainOnClose() async {
        var resume: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(wait: { await withCheckedContinuation { resume = $0 } }, write: { writes.append($0) })
        edit.set(2, saved: 1)
        while resume == nil { await Task.yield() }
        resume?.resume()
        while writes.isEmpty { await Task.yield() }
        await edit.flush()?.value
        assertEquals(writes, [2])
    }

    func testReturningToSavedValueCancelsThePendingEdit() async {
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(write: { writes.append($0) })
        edit.set(2, saved: 1)
        edit.set(1, saved: 1)
        assertNil(edit.draft)
        edit.synchronize(saved: 3) // A later external reload must reach the control.
        assertNil(edit.draft)
        await edit.flush()?.value
        assertEquals(writes, [])
    }

    func testRevertingBeforeReloadPreservesTheLatestEdit() async {
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(write: { writes.append($0) })
        edit.set(2, saved: 1)
        await edit.flush()?.value // Disk write started, but the UI still sees saved == 1.
        edit.set(1, saved: 1)
        edit.synchronize(saved: 2) // Delayed reload of the first write.
        assertEquals(edit.draft, 1)
        await edit.flush()?.value
        assertEquals(writes, [2, 1])
        edit.synchronize(saved: 1)
        assertNil(edit.draft)
    }

    func testClosingBeforeReloadStillWritesTheRevertedValue() async {
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(write: { writes.append($0) })
        edit.set(2, saved: 1)
        await edit.flush()?.value
        edit.set(1, saved: 1)
        await edit.flush()?.value // Window/tab teardown before either reload has acknowledged a write.
        assertEquals(writes, [2, 1])
        edit.synchronize(saved: 2)
        assertEquals(edit.draft, 1)
        edit.synchronize(saved: 1)
        assertNil(edit.draft)
    }

    func testStaleMatchingReloadCannotCancelARevertBehindAnOutstandingWrite() async {
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(write: { writes.append($0) })
        edit.set(2, saved: 1)
        await edit.flush()?.value
        edit.set(1, saved: 1)
        edit.synchronize(saved: 1) // This value predates the outstanding write of 2.
        assertEquals(edit.draft, 1)
        await edit.flush()?.value
        assertEquals(writes, [2, 1])
    }

    func testFailedAppearanceWriteRollsBackAndAllowsRetry() async {
        struct WriteFailure: Error {}
        var attempts: [Int] = []
        var failures = 0
        let edit = DebouncedConfigEdit<Int>(write: {
            attempts.append($0)
            throw WriteFailure()
        }, onFailure: { _ in failures += 1 })
        edit.set(2, saved: 1)
        await edit.flush()?.value
        assertNil(edit.draft) // The control follows the loaded value again.
        edit.set(2, saved: 1)
        await edit.flush()?.value
        assertEquals(attempts, [2, 2])
        assertEquals(failures, 2)
        assertNil(edit.draft)
    }

    func testFailedOlderWritePreservesTheNewerPendingEdit() async {
        var resume: CheckedContinuation<Void, Error>?
        var writes: [Int] = []
        var failures = 0
        let edit = DebouncedConfigEdit<Int>(write: { value in
            writes.append(value)
            if writes.count == 1 { try await withCheckedThrowingContinuation { resume = $0 } }
        }, onFailure: { _ in failures += 1 })
        edit.set(2, saved: 1)
        let firstWrite = edit.flush()
        while resume == nil { await Task.yield() }
        edit.set(3, saved: 1)
        resume?.resume(throwing: CocoaError(.fileWriteNoPermission))
        await firstWrite?.value
        assertEquals(edit.draft, 3)
        await edit.flush()?.value
        assertEquals(writes, [2, 3])
        assertEquals(failures, 1)
        edit.synchronize(saved: 3)
        assertNil(edit.draft)
    }

    func testFailedOlderWriteRequeuesANewerMatchingDraft() async {
        var resume: CheckedContinuation<Void, Error>?
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(write: { value in
            writes.append(value)
            if writes.count == 1 { try await withCheckedThrowingContinuation { resume = $0 } }
        }, onFailure: { _ in })
        edit.set(2, saved: 1)
        let firstWrite = edit.flush()
        while resume == nil { await Task.yield() }
        edit.set(3, saved: 1)
        edit.set(2, saved: 1) // Matches the outstanding submission, so no write is queued yet.
        resume?.resume(throwing: CocoaError(.fileWriteNoPermission))
        await firstWrite?.value
        assertEquals(edit.draft, 2)
        await edit.flush()?.value
        assertEquals(writes, [2, 2])
        edit.synchronize(saved: 2)
        assertNil(edit.draft)
    }

    func testFailedOlderWriteDoesNotForgetANewerSubmission() async {
        var resume: CheckedContinuation<Void, Error>?
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(write: { value in
            writes.append(value)
            if writes.count == 1 { try await withCheckedThrowingContinuation { resume = $0 } }
        }, onFailure: { _ in })
        edit.set(2, saved: 1)
        let firstWrite = edit.flush()
        while resume == nil { await Task.yield() }
        edit.set(3, saved: 1)
        await edit.flush()?.value
        resume?.resume(throwing: CocoaError(.fileWriteNoPermission))
        await firstWrite?.value
        assertEquals(edit.draft, 3)
        edit.set(1, saved: 1) // A revert must still be written behind the newer submission.
        await edit.flush()?.value
        assertEquals(writes, [2, 3, 1])
        edit.synchronize(saved: 1)
        assertNil(edit.draft)
    }

    func testFailureAfterTeardownKeepsANewerMatchingEditAliveUntilWritten() async {
        var resume: CheckedContinuation<Void, Error>?
        var writes: [Int] = []
        var edit: DebouncedConfigEdit<Int>? = DebouncedConfigEdit(write: { value in
            writes.append(value)
            if writes.count == 1 { try await withCheckedThrowingContinuation { resume = $0 } }
        }, onFailure: { _ in })
        edit?.set(2, saved: 1)
        let firstWrite = edit?.flush()
        while resume == nil { await Task.yield() }
        edit?.set(3, saved: 1)
        edit?.set(2, saved: 1)
        edit?.flush() // No pending write: the draft matches the outstanding submission.
        edit = nil // The window/tab released its model.
        resume?.resume(throwing: CocoaError(.fileWriteNoPermission))
        await firstWrite?.value
        assertEquals(writes, [2, 2])
    }

    func testAppearanceReloadRecoversFromPauseAndPauseResumeWithoutRewriting() async {
        for resumeAgain in [false, true] {
            let coordinator = SessionCoordinator()
            var file = 1
            var loaded = 1
            var writes: [Int] = []
            var reloads = 0
            var failures = 0
            var resume: CheckedContinuation<Void, Never>?
            let edit = DebouncedConfigEdit<Int>(write: { value in
                file = value
                writes.append(value)
                try await reloadSettingsConfigAfterWrite(coordinator: coordinator) {
                    reloads += 1
                    let intent = coordinator.latestEnableIntent
                    if reloads == 1 { await withCheckedContinuation { resume = $0 } }
                    if coordinator.isEnabled { try coordinator.validateEnabledSession(intent) }
                    else if !coordinator.isCurrent(intent) { throw CancellationError() }
                    loaded = file
                }
            }, onFailure: { _ in failures += 1 })
            edit.set(2, saved: loaded)
            let write = edit.flush()
            while resume == nil { await Task.yield() }
            _ = coordinator.beginEnableIntent()
            coordinator.setEnabled(false)
            if resumeAgain {
                _ = coordinator.beginEnableIntent()
                coordinator.setEnabled(true)
            }
            // The real light session validates its captured guard after the native query.
            resume?.resume()
            await write?.value
            assertEquals(writes, [2])
            assertEquals(reloads, 2)
            assertEquals(loaded, 2)
            assertEquals(coordinator.isEnabled, resumeAgain)
            assertEquals(failures, 0)
            edit.synchronize(saved: loaded)
            assertNil(edit.draft)
        }
    }

    func testRepeatedEnableChangesRetryOnlyReloadAndKeepLatestIntent() async throws {
        let coordinator = SessionCoordinator()
        var reloads = 0
        var finalIntent = 0
        try await reloadSettingsConfigAfterWrite(coordinator: coordinator) {
            reloads += 1
            if reloads <= 3 {
                finalIntent = coordinator.beginEnableIntent()
                coordinator.setEnabled(!coordinator.isEnabled)
                throw CancellationError()
            }
        }
        assertEquals(reloads, 4)
        assertEquals(coordinator.latestEnableIntent, finalIntent)
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testCancellationWithoutANewerEnableIntentFailsOnceAndRollsBackDraft() async {
        let coordinator = SessionCoordinator()
        var reloads = 0
        var failures = 0
        let edit = DebouncedConfigEdit<Int>(write: { _ in
            try await reloadSettingsConfigAfterWrite(coordinator: coordinator) {
                reloads += 1
                throw CancellationError()
            }
        }, onFailure: { _ in failures += 1 })
        edit.set(2, saved: 1)
        await edit.flush()?.value
        assertEquals(reloads, 1)
        assertEquals(failures, 1)
        assertNil(edit.draft)
    }

    func testTaskCancellationStopsReloadRecoveryEvenWithANewerEnableIntent() async {
        let coordinator = SessionCoordinator()
        var reloads = 0
        var resume: CheckedContinuation<Void, Never>?
        let task = Task {
            try await reloadSettingsConfigAfterWrite(coordinator: coordinator) {
                reloads += 1
                await withCheckedContinuation { resume = $0 }
                throw CancellationError()
            }
        }
        while resume == nil { await Task.yield() }
        _ = coordinator.beginEnableIntent()
        coordinator.setEnabled(false)
        task.cancel()
        resume?.resume()
        do {
            try await task.value
            XCTFail("A canceled owner must not start another reload")
        } catch { assertTrue(error is CancellationError) }
        assertEquals(reloads, 1)
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testCanceledOlderReloadReadsNewerFileInsteadOfRewritingItsOldValue() async {
        let coordinator = SessionCoordinator()
        var file = 1
        var loaded = 1
        var writes: [Int] = []
        var reloads = 0
        var failures = 0
        var resume: CheckedContinuation<Void, Never>?
        let edit = DebouncedConfigEdit<Int>(write: { value in
            writes.append(value)
            file = value
            try await reloadSettingsConfigAfterWrite(coordinator: coordinator) {
                reloads += 1
                let intent = coordinator.latestEnableIntent
                if reloads == 1 { await withCheckedContinuation { resume = $0 } }
                if !coordinator.isCurrent(intent) { throw CancellationError() }
                loaded = file
            }
        }, onFailure: { _ in failures += 1 })
        edit.set(2, saved: loaded)
        let firstWrite = edit.flush()
        while resume == nil { await Task.yield() }
        _ = coordinator.beginEnableIntent()
        coordinator.setEnabled(false)
        edit.set(3, saved: loaded)
        await edit.flush()?.value
        edit.synchronize(saved: loaded)
        assertNil(edit.draft)
        resume?.resume()
        await firstWrite?.value
        assertEquals(writes, [2, 3])
        assertEquals(reloads, 3)
        assertEquals(file, 3)
        assertEquals(loaded, 3)
        assertNil(edit.draft)
        assertEquals(failures, 0)
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testCanceledReloadStillAppliesAfterAppearanceModelIsReleased() async {
        let coordinator = SessionCoordinator()
        var file = 1
        var loaded = 1
        var writes: [Int] = []
        var reloads = 0
        var resume: CheckedContinuation<Void, Never>?
        var edit: DebouncedConfigEdit<Int>? = DebouncedConfigEdit(write: { value in
            file = value
            writes.append(value)
            try await reloadSettingsConfigAfterWrite(coordinator: coordinator) {
                reloads += 1
                let intent = coordinator.latestEnableIntent
                if reloads == 1 { await withCheckedContinuation { resume = $0 } }
                if !coordinator.isCurrent(intent) { throw CancellationError() }
                loaded = file
            }
        }, onFailure: { _ in XCTFail("Enable supersession is recoverable") })
        edit?.set(2, saved: loaded)
        let write = edit?.flush()
        while resume == nil { await Task.yield() }
        edit = nil
        _ = coordinator.beginEnableIntent()
        coordinator.setEnabled(false)
        resume?.resume()
        await write?.value
        assertEquals(writes, [2])
        assertEquals(loaded, 2)
        assertEquals(reloads, 2)
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testReloadFailureAfterEnableSupersessionStillReportsAndRollsBack() async {
        let coordinator = SessionCoordinator()
        var reloads = 0
        var failures = 0
        let edit = DebouncedConfigEdit<Int>(write: { _ in
            try await reloadSettingsConfigAfterWrite(coordinator: coordinator) {
                reloads += 1
                if reloads == 1 {
                    _ = coordinator.beginEnableIntent()
                    coordinator.setEnabled(false)
                    throw CancellationError()
                }
                throw CocoaError(.fileReadNoPermission)
            }
        }, onFailure: { _ in failures += 1 })
        edit.set(2, saved: 1)
        await edit.flush()?.value
        assertEquals(reloads, 2)
        assertEquals(failures, 1)
        assertNil(edit.draft)
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testNoOpDraftCannotMaskExternalReloadAfterCanceledNoncooperativeDebounce() async {
        var resume: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(wait: { await withCheckedContinuation { resume = $0 } }, write: { writes.append($0) })
        edit.set(2, saved: 1)
        while resume == nil { await Task.yield() }
        edit.set(1, saved: 1)
        assertNil(edit.draft)
        edit.synchronize(saved: 3)
        resume?.resume()
        for _ in 0 ..< 10 { await Task.yield() }
        await edit.flush()?.value
        assertEquals(writes, [])
        assertNil(edit.draft)
    }

    func testExternalReloadAcknowledgesAnUnsubmittedDraftAndCancelsItsDebounce() async {
        var resume: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(wait: { await withCheckedContinuation { resume = $0 } }, write: { writes.append($0) })
        edit.set(2, saved: 1)
        while resume == nil { await Task.yield() }
        edit.synchronize(saved: 2)
        assertNil(edit.draft)
        resume?.resume()
        for _ in 0 ..< 10 { await Task.yield() }
        await edit.flush()?.value
        assertEquals(writes, [])
        edit.synchronize(saved: 3)
        assertNil(edit.draft)
    }

    func testDifferentExternalReloadPreservesAnUnsubmittedUserEdit() async {
        var writes: [Int] = []
        let edit = DebouncedConfigEdit<Int>(write: { writes.append($0) })
        edit.set(2, saved: 1)
        edit.synchronize(saved: 3)
        assertEquals(edit.draft, 2)
        await edit.flush()?.value
        assertEquals(writes, [2])
        edit.synchronize(saved: 2)
        assertNil(edit.draft)
        edit.synchronize(saved: 4)
        assertNil(edit.draft)
    }

    func testRejectedUiReloadFailsAppearanceSubmissionWhenEnabledOrPaused() async {
        let originalApp = appForTests
        appForTests = nil
        defer { appForTests = originalApp }
        let originalEnabled = sessionCoordinator.isEnabled
        defer { sessionCoordinator.setEnabled(originalEnabled) }
        // This is valid TOML but not an Airlock config. The writer validates before writing;
        // an external edit between write and reload can still make the reload reject its input.
        let invalid = "[focus-flash]\nmode = 'bogus'"
        XCTAssertFalse(parseConfig(invalid).errors.isEmpty)
        for enabled in [false, true] {
            sessionCoordinator.setEnabled(enabled)
            var writes: [Int] = []
            var reloads = 0
            var failures = 0
            let edit = DebouncedConfigEdit<Int>(write: { value in
                writes.append(value)
                try await reloadSettingsConfigAfterWrite {
                    try await reloadConfigFromUi(.menuBarButton) {
                        reloads += 1
                        return parseConfig(invalid).errors.isEmpty
                    }
                }
            }, onFailure: { _ in failures += 1 })
            edit.set(2, saved: 1)
            await edit.flush()?.value
            assertEquals(writes, [2])
            assertEquals(reloads, 1)
            assertEquals(failures, 1)
            assertNil(edit.draft)
            assertEquals(sessionCoordinator.isEnabled, enabled)
            edit.synchronize(saved: 3)
            assertNil(edit.draft)
        }
    }

    func testAcceptedUiReloadPreservesRunningStateAndRunsOnce() async throws {
        let originalApp = appForTests
        appForTests = nil
        defer { appForTests = originalApp }
        let originalEnabled = sessionCoordinator.isEnabled
        defer { sessionCoordinator.setEnabled(originalEnabled) }
        for enabled in [false, true] {
            sessionCoordinator.setEnabled(enabled)
            var reloads = 0
            try await reloadConfigFromUi(.menuBarButton) {
                reloads += 1
                return true
            }
            assertEquals(reloads, 1)
            assertEquals(sessionCoordinator.isEnabled, enabled)
        }
    }

    func testRejectedOlderUiReloadPreservesANewerSubmissionAndItsRevert() async {
        let originalEnabled = sessionCoordinator.isEnabled
        sessionCoordinator.setEnabled(false)
        defer { sessionCoordinator.setEnabled(originalEnabled) }
        var resume: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        var failures = 0
        let edit = DebouncedConfigEdit<Int>(write: { value in
            writes.append(value)
            try await reloadSettingsConfigAfterWrite {
                try await reloadConfigFromUi(.menuBarButton) {
                    if value == 2 {
                        await withCheckedContinuation { resume = $0 }
                        return false
                    }
                    return true
                }
            }
        }, onFailure: { _ in failures += 1 })
        edit.set(2, saved: 1)
        let firstWrite = edit.flush()
        while resume == nil { await Task.yield() }
        edit.set(3, saved: 1)
        await edit.flush()?.value
        resume?.resume()
        await firstWrite?.value
        assertEquals(failures, 1)
        assertEquals(edit.draft, 3)
        edit.set(1, saved: 1)
        await edit.flush()?.value
        assertEquals(writes, [2, 3, 1])
        edit.synchronize(saved: 1)
        assertNil(edit.draft)
    }

    func testCmdWClosesSettingsWithCapsLockOnOrOff() throws {
        for (modifiers, characters): (NSEvent.ModifierFlags, String) in [
            (.command, "w"), ([.command, .capsLock], "w"), ([.command, .capsLock], "W"),
        ] {
            let result = try settingsCloseShortcut(modifiers: modifiers, characters: characters)
            assertTrue(result.handled)
            assertEquals(result.closes, 1)
        }
    }

    func testSettingsCloseShortcutRejectsMeaningfulExtraModifiersAndOtherKeys() throws {
        for modifiers: NSEvent.ModifierFlags in [
            [], .capsLock, [.command, .shift], [.command, .option], [.command, .control],
            [.command, .capsLock, .shift], [.command, .function],
        ] {
            let result = try settingsCloseShortcut(modifiers: modifiers, characters: "w")
            assertEquals(result.closes, 0)
        }
        assertEquals(try settingsCloseShortcut(modifiers: .command, characters: "q").closes, 0)
    }

    private func settingsCloseShortcut(modifiers: NSEvent.ModifierFlags, characters: String) throws -> (handled: Bool, closes: Int) {
        _ = NSApplication.shared
        // This test window is never shown or activated. Only the synthetic event has Caps Lock set.
        let window = AgentWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var closes = 0
        let observation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { closes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 13))
        return (window.performKeyEquivalent(with: event), closes)
    }
}
