@testable import AppBundle
import Common
import XCTest

@MainActor
final class MultiMonitorConfigTest: XCTestCase {
    func testDefaults() {
        let (config, errors) = parseConfig("")
        assertEquals(errors.descriptions, [])
        assertEquals(config.appSwitchingScope, .workspace)
        assertEquals(config.multiMonitor, .default)
        assertEquals(config.preventFocusStealing(monitorCount: 2), .crossWorkspace)
        assertEquals(config.appSwitchingScope(monitorCount: 2), .workspace)
    }

    func testMultiMonitorValuesApplyOnlyWithMoreThanOneMonitor() {
        let (config, errors) = parseConfig("""
            prevent-focus-stealing = 'cross-workspace'
            app-switching-scope = 'workspace'

            [multi-monitor]
                prevent-focus-stealing = 'off'
                app-switching-scope = 'all'
            """)
        assertEquals(errors.descriptions, [])
        assertEquals(config.preventFocusStealing(monitorCount: 1), .crossWorkspace)
        assertEquals(config.appSwitchingScope(monitorCount: 1), .workspace)
        assertEquals(config.preventFocusStealing(monitorCount: 2), .off)
        assertEquals(config.appSwitchingScope(monitorCount: 3), .all)
    }

    func testUnsetMultiMonitorValueKeepsTheTopLevelValue() {
        let (config, errors) = parseConfig("""
            prevent-focus-stealing = 'always'
            app-switching-scope = 'all'

            [multi-monitor]
                prevent-focus-stealing = 'off'
            """)
        assertEquals(errors.descriptions, [])
        assertEquals(config.preventFocusStealing(monitorCount: 2), .off)
        assertEquals(config.appSwitchingScope(monitorCount: 2), .all)
    }

    func testInvalidValuesAreErrors() {
        let (_, errors) = parseConfig("""
            app-switching-scope = 'everywhere'

            [multi-monitor]
                app-switching-scope = 'nowhere'
                prevent-focus-stealing = 'sometimes'
                enable-window-management = false
            """)
        assertEquals(errors.count, 4)
        XCTAssertTrue(errors.descriptions.contains { $0.contains("app-switching-scope 'everywhere'") })
        XCTAssertTrue(errors.descriptions.contains { $0.contains("app-switching-scope 'nowhere'") })
        XCTAssertTrue(errors.descriptions.contains { $0.contains("prevent-focus-stealing 'sometimes'") })
        XCTAssertTrue(errors.descriptions.contains { $0.contains("multi-monitor.enable-window-management") })
    }
}
