@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusFlashConfigTest: XCTestCase {
    func testDefaultsWhenTableMissing() {
        let (config, errors) = parseConfig("")
        assertEquals(errors.descriptions, [])
        assertEquals(config.focusFlash.enabled, true)
        assertEquals(config.focusFlash.mode, .crossWorkspace)
        assertEquals(config.focusFlash.idleThresholdSeconds, 10)
        assertEquals(config.focusFlash.color, "0xff00ff00")
        assertEquals(config.focusFlash.width, 6.0)
        assertEquals(config.focusFlash.popDistance, 10.0)
        assertEquals(config.focusFlash.durationMs, 400)
    }

    func testDefaultsWhenTableEmpty() {
        let (config, errors) = parseConfig("[focus-flash]")
        assertEquals(errors.descriptions, [])
        assertEquals(config.focusFlash.enabled, true)
        assertEquals(config.focusFlash.mode, .crossWorkspace)
    }

    func testFullConfig() {
        let (config, errors) = parseConfig("""
                [focus-flash]
                enabled = false
                mode = 'idle'
                idle-threshold-seconds = 30
                color = '0xffff0000'
                width = 3.5
                pop-distance = 20.0
                duration-ms = 800
            """)
        assertEquals(errors.descriptions, [])
        assertEquals(config.focusFlash.enabled, false)
        assertEquals(config.focusFlash.mode, .idle)
        assertEquals(config.focusFlash.idleThresholdSeconds, 30)
        assertEquals(config.focusFlash.color, "0xffff0000")
        assertEquals(config.focusFlash.width, 3.5)
        assertEquals(config.focusFlash.popDistance, 20.0)
        assertEquals(config.focusFlash.durationMs, 800)
    }

    func testInvalidModeProducesError() {
        let (_, errors) = parseConfig("""
                [focus-flash]
                mode = 'bogus'
            """)
        assertEquals(errors.descriptions.count, 1)
        XCTAssertTrue(errors.descriptions[0].contains("mode"))
    }

    func testInvalidColorProducesError() {
        let (_, errors) = parseConfig("""
                [focus-flash]
                color = 'not-a-hex'
            """)
        assertEquals(errors.descriptions.count, 1)
        XCTAssertTrue(errors.descriptions[0].contains("color"))
    }
}
