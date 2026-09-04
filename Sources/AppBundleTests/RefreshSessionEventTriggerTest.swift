@testable import AppBundle
import Common
import Foundation
import XCTest

/// `trigger` goes into the `airlock subscribe` JSON stream, so it must stay short and stable.
/// `description` is for crash reports and may embed a whole command; `trigger` must not.
final class RefreshSessionEventTriggerTest: XCTestCase {
    func testTriggerNamesTheCommandWithoutItsArguments() {
        guard case .cmd(let command) = parseCommand("move-node-to-workspace --focus-follows-window 7") else {
            XCTFail("failed to parse the command"); return
        }
        let trigger = RefreshSessionEvent.socketServer(command.args).trigger
        XCTAssertEqual(trigger, "socket-server(move-node-to-workspace)")
        XCTAssertFalse(trigger.contains("7"))
        XCTAssertFalse(trigger.contains("--focus-follows-window"))
    }

    func testTriggerKeepsTheNotificationName() {
        XCTAssertEqual(
            RefreshSessionEvent.ax("kAXFocusedWindowChangedNotification").trigger,
            "ax(kAXFocusedWindowChangedNotification)",
        )
        XCTAssertEqual(
            RefreshSessionEvent.globalObserver("NSWorkspaceDidActivateApplicationNotification").trigger,
            "global-observer(NSWorkspaceDidActivateApplicationNotification)",
        )
    }

    func testArgumentlessTriggersAreKebabCase() {
        let triggers: [RefreshSessionEvent] = [
            .configAutoReload, .globalObserverLeftMouseUp, .menuBarButton, .hotkeyBinding, .startup,
            .resetManipulatedWithMouse, .onFocusedMonitorChanged, .onFocusChanged, .onModeChanged,
        ]
        for event in triggers {
            let trigger = event.trigger
            XCTAssertFalse(trigger.isEmpty, "\(event) has an empty trigger")
            XCTAssertEqual(
                trigger, trigger.lowercased(),
                "'\(trigger)' should be kebab-case, so subscribers can match on it",
            )
        }
    }

    /// The stream is the whole point of the field, so pin the wire format.
    func testTriggerIsSerializedAndOmittedWhenAbsent() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]

        let withTrigger = ServerEvent.focusChanged(windowId: 42, workspace: "1", trigger: "hotkey-binding")
        XCTAssertEqual(
            String(decoding: try encoder.encode(withTrigger), as: UTF8.self),
            #"{"_event":"focus-changed","trigger":"hotkey-binding","windowId":42,"workspace":"1"}"#,
        )

        let withoutTrigger = ServerEvent.focusChanged(windowId: 42, workspace: "1")
        XCTAssertEqual(
            String(decoding: try encoder.encode(withoutTrigger), as: UTF8.self),
            #"{"_event":"focus-changed","windowId":42,"workspace":"1"}"#,
        )
    }
}
