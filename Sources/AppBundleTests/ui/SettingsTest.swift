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

        assertEquals(disabled, ["enable-workspace-app-switching", "focus-workspace-on-mouse-click"])
        assertEquals(unmetReason(.windowManagement, config), "Requires Window management, which is off.")
        assertNotNil(unmetReason(preventFocusStealingRequirement, config))
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
}
