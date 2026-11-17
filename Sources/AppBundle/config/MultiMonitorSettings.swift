import AppKit
import Common
import TOMLKit

/// The `[multi-monitor]` table. Each value set here replaces the top-level value of the same key
/// while more than one monitor is connected. An unset value leaves the top-level one in effect.
struct MultiMonitorSettings: ConvenienceCopyable, Equatable, Sendable {
    var preventFocusStealing: PreventFocusStealingMode? = nil
    var appSwitchingScope: AppSwitchingScope? = nil

    static let `default` = MultiMonitorSettings()
}

let multiMonitorTableKey = "multi-monitor"

private let multiMonitorParser: [String: any ParserProtocol<MultiMonitorSettings>] = [
    "prevent-focus-stealing": Parser(\.preventFocusStealing) { parsePreventFocusStealing($0, $1).map(Optional.some) },
    "app-switching-scope": Parser(\.appSwitchingScope) { parseAppSwitchingScope($0, $1).map(Optional.some) },
]

func parseMultiMonitor(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> MultiMonitorSettings {
    parseTable(raw, .default, multiMonitorParser, backtrace, &errors)
}

extension Config {
    /// `prevent-focus-stealing` with the `[multi-monitor]` value applied when it applies
    func preventFocusStealing(monitorCount: Int) -> PreventFocusStealingMode {
        monitorCount > 1 ? multiMonitor.preventFocusStealing ?? preventFocusStealing : preventFocusStealing
    }

    /// `app-switching-scope` with the `[multi-monitor]` value applied when it applies
    func appSwitchingScope(monitorCount: Int) -> AppSwitchingScope {
        monitorCount > 1 ? multiMonitor.appSwitchingScope ?? appSwitchingScope : appSwitchingScope
    }

    /// The `prevent-focus-stealing` mode in effect with the monitors connected right now
    @MainActor var activePreventFocusStealing: PreventFocusStealingMode {
        preventFocusStealing(monitorCount: connectedMonitorCount)
    }

    /// The `app-switching-scope` in effect with the monitors connected right now
    @MainActor var activeAppSwitchingScope: AppSwitchingScope {
        appSwitchingScope(monitorCount: connectedMonitorCount)
    }
}

/// Mirrored displays count once, as they do in `NSScreen.screens`. Unit tests always have one monitor
@MainActor var connectedMonitorCount: Int {
    isUnitTest ? monitors.count : NSScreen.screens.count
}
