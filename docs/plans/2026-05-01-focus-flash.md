# Focus Flash Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a transient pulsing-outline overlay drawn on the focused window when focus changes (auto, configurable trigger) and on a hotkey command (`flash-focus`).

**Architecture:** New `[focus-flash]` TOML table mirrors the existing `[quick-switcher]` pattern. New built-in command `flash-focus` follows the existing zero-arg-command pattern. A `FocusFlashController` owns one reusable borderless `NSPanel` (modeled on `NSPanelHud`) hosting an `NSView` that draws an outline via `CAShapeLayer` and animates expand+fade with `CABasicAnimation`. Auto-flash is plumbed into the existing `checkOnFocusChangedCallbacks()` hook in `focus.swift`.

**Tech Stack:** Swift, AppKit (`NSPanel`, `NSView`, `CAShapeLayer`, `CABasicAnimation`), XCTest. TOML parsing via the project's existing `ParserProtocol` and `parseTable` helpers.

---

## Conventions Reference

Quoted patterns the engineer should mirror — collected so the engineer doesn't have to re-derive them.

**Config table struct + parser** (precedent: `Sources/AppBundle/config/QuickSwitcherSettings.swift`):

```swift
struct QuickSwitcherSettings: ConvenienceCopyable, Equatable, Sendable {
    var enabled: Bool = true
    var binding: String = "option-space"
    static let `default` = QuickSwitcherSettings()
}

private let quickSwitcherParser: [String: any ParserProtocol<QuickSwitcherSettings>] = [
    "enabled": Parser(\.enabled, parseBool),
    "binding": Parser(\.binding, parseString),
]

func parseQuickSwitcher(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> QuickSwitcherSettings {
    parseTable(raw, .default, quickSwitcherParser, backtrace, &errors)
}
```

**Config registration** (`Sources/AppBundle/config/Config.swift` ~ line 35-66):

```swift
struct Config: ConvenienceCopyable {
    // ...
    var quickSwitcher: QuickSwitcherSettings = .default
}
```

**Top-level parser registration** (`Sources/AppBundle/config/parseConfig.swift:122`):

```swift
private let configParser: [String: any ParserProtocol<Config>] = [
    // ...
    "quick-switcher": Parser(\.quickSwitcher, parseQuickSwitcher),
    // ...
]
```

**Borderless overlay panel** (`Sources/AppBundle/ui/NSPanelHud.swift`):

```swift
open class NSPanelHud: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow, .utilityWindow],
            backing: .buffered, defer: false,
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.alphaValue = 1
        self.hasShadow = true
        self.backgroundColor = .clear
    }
}
```

**Command kind enum** (`Sources/Common/cmdArgs/cmdArgsManifest.swift:1-46`):

```swift
public enum CmdKind: String, CaseIterable, Equatable, Sendable {
    case focus
    case focusBackAndForth = "focus-back-and-forth"
    case focusMonitor = "focus-monitor"
    // ← insert: case flashFocus = "flash-focus"
    case fullscreen
    // ...
}
```

**Zero-arg-ish command args struct** (precedent: `Sources/Common/cmdArgs/impl/ModeCmdArgs.swift:1-15`):

```swift
public struct ModeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .mode, allowInConfig: true, help: mode_help_generated,
        flags: [:], posArgs: [/* positional args here */],
    )
    public var targetMode: Lateinit<String> = .uninitialized
}
```

**Command implementation** (precedent: `Sources/AppBundle/command/impl/ModeCommand.swift:1-12`):

```swift
struct ModeCommand: Command {
    let args: ModeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool { /* ... */ }
}
```

**Focus-change hook** (`Sources/AppBundle/focus.swift:139-173`, function `checkOnFocusChangedCallbacks()`). Insert after `if hasFocusChanged {` (around line 164):

```swift
if hasFocusChanged {
    // ← insert auto-flash hook here
    onFocusChanged(focus)
}
```

`_prevFocus` (`FrozenFocus`, line 129) holds the prior focus snapshot; `_prevFocusedWorkspaceName` (line 120) holds the prior workspace name.

**Config parsing test** (precedent: `Sources/AppBundleTests/config/ConfigTest.swift:22-39`):

```swift
@MainActor
final class ConfigTest: XCTestCase {
    func testConfigVersionOutOfBounds() {
        let (_, errors) = parseConfig("config-version = 0")
        assertEquals(errors.descriptions, ["config-version: Must be in [1, 2] range"])
    }
}
```

`parseConfig(_ tomlString:)` returns `(Config, [TomlParseError])`. Use `assertEquals(actual, expected)` and `errors.descriptions` for assertions.

---

## Schema Note

The design doc used `enable = true` as the master switch. **The implementation will use `enabled = true` instead** to match the established `[quick-switcher]` convention (which uses `enabled`). Functional behavior unchanged.

Final TOML schema:

```toml
[focus-flash]
enabled = true                  # bool, default true. Master switch.
mode = "cross-workspace"        # one of: every, cross-workspace, cross-app, idle, off
idle-threshold-seconds = 10     # int, used only when mode = "idle"
color = "0xff00ff00"            # AARRGGBB hex string
width = 6.0                     # double, pt
pop-distance = 10.0             # double, pt outward expansion
duration-ms = 400               # int, total animation length
```

---

## Tasks

### Task 1: Add `FocusFlashMode` enum (Common) with TOML parser

**Files:**
- Create: `Sources/Common/FocusFlashMode.swift`
- Test: `Sources/AppBundleTests/config/FocusFlashConfigTest.swift` (created later in Task 2)

**Step 1: Write the enum**

```swift
// Sources/Common/FocusFlashMode.swift
public enum FocusFlashMode: String, Equatable, Sendable, CaseIterable {
    case every = "every"
    case crossWorkspace = "cross-workspace"
    case crossApp = "cross-app"
    case idle = "idle"
    case off = "off"
}
```

**Step 2: Build to verify it compiles**

Run: `./build.sh`
Expected: build succeeds, tests still pass (no behavior change yet).

**Step 3: Commit**

```bash
git add Sources/Common/FocusFlashMode.swift
git commit -m "Add FocusFlashMode enum"
```

---

### Task 2: Add `FocusFlashSettings` struct + parser, register in `Config`

**Files:**
- Create: `Sources/AppBundle/config/FocusFlashSettings.swift`
- Modify: `Sources/AppBundle/config/Config.swift` (add `var focusFlash: FocusFlashSettings = .default`)
- Modify: `Sources/AppBundle/config/parseConfig.swift` (add `"focus-flash": Parser(\.focusFlash, parseFocusFlash)` to `configParser` dict ~line 122)
- Create: `Sources/AppBundleTests/config/FocusFlashConfigTest.swift`

**Step 1: Write the failing tests first**

```swift
// Sources/AppBundleTests/config/FocusFlashConfigTest.swift
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
```

**Step 2: Run tests to verify they fail**

Run: `./build.sh`
Expected: compile errors — `config.focusFlash` doesn't exist yet.

**Step 3: Write the settings struct + parser**

```swift
// Sources/AppBundle/config/FocusFlashSettings.swift
import Common
import TOMLKit

struct FocusFlashSettings: ConvenienceCopyable, Equatable, Sendable {
    var enabled: Bool = true
    var mode: FocusFlashMode = .crossWorkspace
    var idleThresholdSeconds: Int = 10
    var color: String = "0xff00ff00"
    var width: Double = 6.0
    var popDistance: Double = 10.0
    var durationMs: Int = 400

    static let `default` = FocusFlashSettings()
}

private let focusFlashParser: [String: any ParserProtocol<FocusFlashSettings>] = [
    "enabled": Parser(\.enabled, parseBool),
    "mode": Parser(\.mode, parseFocusFlashMode),
    "idle-threshold-seconds": Parser(\.idleThresholdSeconds, parseInt),
    "color": Parser(\.color, parseFocusFlashColor),
    "width": Parser(\.width, parseDouble),
    "pop-distance": Parser(\.popDistance, parseDouble),
    "duration-ms": Parser(\.durationMs, parseInt),
]

func parseFocusFlash(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> FocusFlashSettings {
    parseTable(raw, .default, focusFlashParser, backtrace, &errors)
}

private func parseFocusFlashMode(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<FocusFlashMode> {
    parseString(raw, backtrace).flatMap { str in
        if let mode = FocusFlashMode(rawValue: str) {
            return .success(mode)
        }
        let valid = FocusFlashMode.allCases.map(\.rawValue).joined(separator: ", ")
        return .failure(.semantic(backtrace, "mode: '\(str)' is not a valid mode. Valid: \(valid)"))
    }
}

private func parseFocusFlashColor(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<String> {
    parseString(raw, backtrace).flatMap { str in
        // Accept "0x" + 8 hex chars (AARRGGBB).
        let pattern = #"^0[xX][0-9a-fA-F]{8}$"#
        if str.range(of: pattern, options: .regularExpression) != nil {
            return .success(str)
        }
        return .failure(.semantic(backtrace, "color: '\(str)' must be of form 0xAARRGGBB"))
    }
}
```

**Step 4: Wire into `Config` and the top-level parser**

In `Sources/AppBundle/config/Config.swift`, add to the `Config` struct (alongside `quickSwitcher`):

```swift
var focusFlash: FocusFlashSettings = .default
```

In `Sources/AppBundle/config/parseConfig.swift`, add to the `configParser` dict (alongside `"quick-switcher"`):

```swift
"focus-flash": Parser(\.focusFlash, parseFocusFlash),
```

**Step 5: Verify the helper signatures used above exist**

Grep for `parseInt`, `parseDouble`, `parseBool`, `parseString`, `ParsedToml`, `TomlParseError.semantic` in `Sources/AppBundle/config/` to confirm exact names. If any helper doesn't exist (e.g. no `parseInt`), find the actual name (likely `parseInteger` or similar) and update the parser dict accordingly. **Do not invent helpers.**

**Step 6: Run tests**

Run: `./build.sh`
Expected: PASS for all 5 tests in `FocusFlashConfigTest`.

**Step 7: Commit**

```bash
git add Sources/AppBundle/config/FocusFlashSettings.swift \
        Sources/AppBundle/config/Config.swift \
        Sources/AppBundle/config/parseConfig.swift \
        Sources/AppBundleTests/config/FocusFlashConfigTest.swift
git commit -m "Add [focus-flash] config table parsing"
```

---

### Task 3: Add `flash-focus` command kind, args, and command struct (no-op for now)

**Files:**
- Modify: `Sources/Common/cmdArgs/cmdArgsManifest.swift` (add `case flashFocus`)
- Create: `Sources/Common/cmdArgs/impl/FlashFocusCmdArgs.swift`
- Create: `Sources/AppBundle/command/impl/FlashFocusCommand.swift`
- Modify: `Sources/AppBundle/command/cmdManifest.swift` (add mapping)
- Modify: `Sources/Common/cmdArgs/cmdArgsManifest.swift` (`initSubcommands()` registration)
- Test: `Sources/AppBundleTests/command/ParseCommandTest.swift` (add a parse test)

**Step 1: Write the failing test for command parsing**

In `Sources/AppBundleTests/command/ParseCommandTest.swift`, add:

```swift
func testParseFlashFocus() {
    let parsed = try! parseCommand("flash-focus").get()
    XCTAssertTrue(parsed is FlashFocusCmdArgs)
}

func testParseFlashFocusRejectsArgs() {
    let result = parseCommand("flash-focus extra")
    XCTAssertTrue(result.isFailure)
}
```

(If `parseCommand` is named differently in this project, find the existing parse-command test and copy its style.)

**Step 2: Run to verify failure**

Run: `./build.sh`
Expected: compile error — `FlashFocusCmdArgs` doesn't exist.

**Step 3: Add the enum case**

In `Sources/Common/cmdArgs/cmdArgsManifest.swift`, in the `CmdKind` enum (currently around lines 1-46), insert alphabetically after `case focusMonitor`:

```swift
case flashFocus = "flash-focus"
```

In the same file, in `initSubcommands()` (~ lines 48-141), insert alphabetically:

```swift
case .flashFocus:
    result[kind.rawValue] = SubCommandParser(FlashFocusCmdArgs.init)
```

**Step 4: Add the args struct**

```swift
// Sources/Common/cmdArgs/impl/FlashFocusCmdArgs.swift
public struct FlashFocusCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .flashFocus,
        allowInConfig: true,
        help: flash_focus_help_generated,
        flags: [:],
        posArgs: [],
    )
}
```

`flash_focus_help_generated` likely needs to come from a generated help file. Check how `mode_help_generated` is generated (probably from `docs/airlock-mode.adoc` via build script). For Task 3, if the generation step is non-trivial, define `let flash_focus_help_generated = "Flash an outline around the focused window"` as a temporary constant in the same file, and circle back in Task 8 to wire up real docs/help generation. **Investigate before deciding** — grep for `mode_help_generated` to find where it lives.

**Step 5: Add the command implementation (no-op for now)**

```swift
// Sources/AppBundle/command/impl/FlashFocusCommand.swift
import AppKit
import Common

struct FlashFocusCommand: Command {
    let args: FlashFocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        // Wired in Task 7 once FocusFlashController exists.
        return true
    }
}
```

**Step 6: Add the manifest mapping**

In `Sources/AppBundle/command/cmdManifest.swift`, in the existing kind-to-Command switch, add:

```swift
case .flashFocus:
    command = FlashFocusCommand(args: self as! FlashFocusCmdArgs)
```

**Step 7: Run tests**

Run: `./build.sh`
Expected: all tests pass, including the two new parse tests.

**Step 8: Commit**

```bash
git add Sources/Common/cmdArgs/cmdArgsManifest.swift \
        Sources/Common/cmdArgs/impl/FlashFocusCmdArgs.swift \
        Sources/AppBundle/command/impl/FlashFocusCommand.swift \
        Sources/AppBundle/command/cmdManifest.swift \
        Sources/AppBundleTests/command/ParseCommandTest.swift
git commit -m "Add flash-focus command (no-op stub)"
```

---

### Task 4: Implement `FocusFlashOverlay` (the rendering panel)

**Files:**
- Create: `Sources/AppBundle/ui/FocusFlashOverlay.swift`

**Step 1: Write the overlay panel + view**

```swift
// Sources/AppBundle/ui/FocusFlashOverlay.swift
import AppKit
import QuartzCore

@MainActor
final class FocusFlashOverlay {
    private let panel: NSPanel
    private let outlineLayer: CAShapeLayer

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = view

        let outlineLayer = CAShapeLayer()
        outlineLayer.fillColor = NSColor.clear.cgColor
        outlineLayer.lineJoin = .round
        view.layer?.addSublayer(outlineLayer)

        self.panel = panel
        self.outlineLayer = outlineLayer
    }

    /// Cancel any in-flight animation and start a new pulse on `targetFrame`.
    /// `targetFrame` is in screen coordinates (bottom-left origin, like NSScreen).
    func flash(targetFrame: NSRect, color: NSColor, width: CGFloat, popDistance: CGFloat, duration: TimeInterval) {
        cancel()

        // Panel must contain both the tight rect and the popped-out rect, so size it
        // to the popped frame plus a few pt of slack for line width.
        let slack = width + 2
        let popped = targetFrame.insetBy(dx: -popDistance, dy: -popDistance)
        let panelFrame = popped.insetBy(dx: -slack, dy: -slack)
        panel.setFrame(panelFrame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelFrame.size)
        outlineLayer.frame = panel.contentView?.bounds ?? .zero

        // Initial path: tight outline rect (in panel-local coords).
        let tightLocal = NSRect(
            x: targetFrame.minX - panelFrame.minX,
            y: targetFrame.minY - panelFrame.minY,
            width: targetFrame.width,
            height: targetFrame.height,
        )
        let poppedLocal = tightLocal.insetBy(dx: -popDistance, dy: -popDistance)

        outlineLayer.lineWidth = width
        outlineLayer.strokeColor = color.cgColor
        outlineLayer.path = CGPath(rect: tightLocal, transform: nil)
        outlineLayer.opacity = 1.0

        panel.orderFront(nil)

        // Animate path expansion + opacity fade together.
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setCompletionBlock { [weak self] in
            self?.panel.orderOut(nil)
        }

        let pathAnim = CABasicAnimation(keyPath: "path")
        pathAnim.fromValue = CGPath(rect: tightLocal, transform: nil)
        pathAnim.toValue = CGPath(rect: poppedLocal, transform: nil)
        pathAnim.duration = duration
        pathAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pathAnim.fillMode = .forwards
        pathAnim.isRemovedOnCompletion = false

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue = 0.0
        opacityAnim.duration = duration
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        opacityAnim.fillMode = .forwards
        opacityAnim.isRemovedOnCompletion = false

        outlineLayer.add(pathAnim, forKey: "pathPop")
        outlineLayer.add(opacityAnim, forKey: "fade")

        CATransaction.commit()
    }

    /// Stop any in-flight animation and hide the panel.
    func cancel() {
        outlineLayer.removeAnimation(forKey: "pathPop")
        outlineLayer.removeAnimation(forKey: "fade")
        outlineLayer.opacity = 0
        panel.orderOut(nil)
    }
}
```

**Step 2: Build to verify it compiles**

Run: `./build.sh`
Expected: compile succeeds.

**Step 3: Commit**

```bash
git add Sources/AppBundle/ui/FocusFlashOverlay.swift
git commit -m "Add FocusFlashOverlay panel with animated outline pulse"
```

**Note:** Pure UI; no unit test. Manual smoke test happens in Task 9.

---

### Task 5: Implement `FocusFlashController` (owns overlay, applies edge-case rules)

**Files:**
- Create: `Sources/AppBundle/FocusFlashController.swift`
- Test: `Sources/AppBundleTests/FocusFlashControllerTest.swift`

**Step 1: Write the controller**

```swift
// Sources/AppBundle/FocusFlashController.swift
import AppKit
import Common

@MainActor
final class FocusFlashController {
    static let shared = FocusFlashController()

    private lazy var overlay = FocusFlashOverlay()

    /// Public entry point — fire a flash on the given window if it's eligible.
    /// Caller is responsible for the `enabled`/`mode` predicate; this method only
    /// handles "is this window flashable?" edge cases.
    func flash(window: Window?) {
        guard let window else { return }

        // Skip non-real windows.
        switch window.layoutReason {
        case .macosPopupWindow, .macosNativeHiddenAppWindow:
            return
        default:
            break
        }

        // Resolve frame; bail if unavailable (window may have closed/minimized).
        guard let frame = currentScreenFrame(of: window), frame.width > 0, frame.height > 0 else {
            return
        }

        // Skip windows in native-fullscreen Spaces — overlays can't reliably render there.
        if isNativeFullscreen(window) {
            return
        }

        let cfg = config.focusFlash
        guard cfg.enabled else { return }

        let nsColor = parseAARRGGBB(cfg.color) ?? .green
        overlay.flash(
            targetFrame: frame,
            color: nsColor,
            width: CGFloat(cfg.width),
            popDistance: CGFloat(cfg.popDistance),
            duration: TimeInterval(cfg.durationMs) / 1000.0,
        )
    }

    // MARK: - Helpers

    private func currentScreenFrame(of window: Window) -> NSRect? {
        // Use existing window-frame APIs. Find the actual call by grepping for
        // frame access in Sources/AppBundle/tree/MacWindow.swift.
        // Placeholder — replace with the real call:
        return window.lastAppliedLayoutPhysicalRect?.toNSRect()
    }

    private func isNativeFullscreen(_ window: Window) -> Bool {
        // Find existing fullscreen detection in the codebase. Placeholder:
        return false
    }
}

func parseAARRGGBB(_ str: String) -> NSColor? {
    var s = str
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    guard s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
    let a = CGFloat((value >> 24) & 0xff) / 255.0
    let r = CGFloat((value >> 16) & 0xff) / 255.0
    let g = CGFloat((value >> 8)  & 0xff) / 255.0
    let b = CGFloat(value         & 0xff) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
```

**Investigate before completing:** the placeholders `currentScreenFrame(of:)` and `isNativeFullscreen(_:)` need real implementations. Grep:

```bash
grep -rn "lastAppliedLayoutPhysicalRect\|getRect\|axFrame" Sources/AppBundle/tree/
grep -rn "fullscreen\|fullScreen\|isFullScreen" Sources/AppBundle/
```

Find the canonical "give me this window's screen frame" call and the canonical "is this window in a native-fullscreen space" check, and use them. **Do not invent APIs.** If `isNativeFullscreen` cannot be cleanly detected, it's acceptable to leave it returning `false` and document that as a known limitation in the PR description.

**Step 2: Write the color-parser unit test**

```swift
// Sources/AppBundleTests/FocusFlashControllerTest.swift
@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class FocusFlashControllerTest: XCTestCase {
    func testParseAARRGGBB_validFullOpacityGreen() {
        let c = parseAARRGGBB("0xff00ff00")
        XCTAssertNotNil(c)
        let srgb = c!.usingColorSpace(.sRGB)!
        assertEquals(srgb.alphaComponent, 1.0)
        assertEquals(srgb.redComponent, 0.0)
        assertEquals(srgb.greenComponent, 1.0)
        assertEquals(srgb.blueComponent, 0.0)
    }

    func testParseAARRGGBB_validHalfTransparentRed() {
        let c = parseAARRGGBB("0x80ff0000")
        XCTAssertNotNil(c)
        let srgb = c!.usingColorSpace(.sRGB)!
        XCTAssertEqual(srgb.alphaComponent, 128.0/255.0, accuracy: 0.001)
        assertEquals(srgb.redComponent, 1.0)
    }

    func testParseAARRGGBB_rejectsShortString() {
        XCTAssertNil(parseAARRGGBB("0xff00"))
    }

    func testParseAARRGGBB_rejectsNonHex() {
        XCTAssertNil(parseAARRGGBB("0xggggggg0"))
    }

    func testParseAARRGGBB_acceptsCapitalX() {
        XCTAssertNotNil(parseAARRGGBB("0Xff000000"))
    }
}
```

**Step 3: Run tests**

Run: `./build.sh`
Expected: 5 new color-parser tests pass.

**Step 4: Commit**

```bash
git add Sources/AppBundle/FocusFlashController.swift \
        Sources/AppBundleTests/FocusFlashControllerTest.swift
git commit -m "Add FocusFlashController with edge-case handling"
```

---

### Task 6: Add the auto-flash predicate + plumb into focus.swift

**Files:**
- Create: `Sources/AppBundle/FocusFlashPredicate.swift`
- Modify: `Sources/AppBundle/focus.swift` (insert in `checkOnFocusChangedCallbacks()` ~line 164)
- Test: `Sources/AppBundleTests/FocusFlashPredicateTest.swift`

**Step 1: Write the failing tests**

```swift
// Sources/AppBundleTests/FocusFlashPredicateTest.swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusFlashPredicateTest: XCTestCase {
    func testOff_neverFires() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .off,
            prevWorkspace: "A", currWorkspace: "B",
            prevAppId: "com.foo", currAppId: "com.bar",
            secondsSincePrev: 100, idleThreshold: 10,
        ))
    }

    func testEvery_alwaysFires() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .every,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossWorkspace_firesOnSwitch() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .crossWorkspace,
            prevWorkspace: "A", currWorkspace: "B",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossWorkspace_skipsSameWorkspace() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .crossWorkspace,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.bar",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossApp_firesOnAppChange() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .crossApp,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.bar",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testCrossApp_skipsSameApp() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .crossApp,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 0.1, idleThreshold: 10,
        ))
    }

    func testIdle_firesAfterThreshold() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .idle,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 11, idleThreshold: 10,
        ))
    }

    func testIdle_skipsBeforeThreshold() {
        XCTAssertFalse(shouldAutoFlash(
            mode: .idle,
            prevWorkspace: "A", currWorkspace: "A",
            prevAppId: "com.foo", currAppId: "com.foo",
            secondsSincePrev: 5, idleThreshold: 10,
        ))
    }

    func testIdle_firesOnFirstEverFocus() {
        // No previous focus → secondsSincePrev = .infinity sentinel.
        XCTAssertTrue(shouldAutoFlash(
            mode: .idle,
            prevWorkspace: nil, currWorkspace: "A",
            prevAppId: nil, currAppId: "com.foo",
            secondsSincePrev: .infinity, idleThreshold: 10,
        ))
    }

    func testCrossWorkspace_firesOnFirstEverFocus() {
        XCTAssertTrue(shouldAutoFlash(
            mode: .crossWorkspace,
            prevWorkspace: nil, currWorkspace: "A",
            prevAppId: nil, currAppId: "com.foo",
            secondsSincePrev: .infinity, idleThreshold: 10,
        ))
    }
}
```

**Step 2: Run tests, verify failure**

Run: `./build.sh`
Expected: compile error — `shouldAutoFlash` doesn't exist.

**Step 3: Implement the predicate**

```swift
// Sources/AppBundle/FocusFlashPredicate.swift
import Common

func shouldAutoFlash(
    mode: FocusFlashMode,
    prevWorkspace: String?,
    currWorkspace: String?,
    prevAppId: String?,
    currAppId: String?,
    secondsSincePrev: Double,
    idleThreshold: Int,
) -> Bool {
    switch mode {
    case .off:
        return false
    case .every:
        return true
    case .crossWorkspace:
        return prevWorkspace != currWorkspace
    case .crossApp:
        return prevAppId != currAppId
    case .idle:
        return secondsSincePrev >= Double(idleThreshold)
    }
}
```

**Step 4: Plumb into focus.swift**

In `Sources/AppBundle/focus.swift`, locate `checkOnFocusChangedCallbacks()` (currently around lines 139-173). Find the block:

```swift
if hasFocusChanged {
    onFocusChanged(focus)
}
```

Modify to:

```swift
if hasFocusChanged {
    maybeAutoFlash(prev: _prevFocus, curr: focus)
    onFocusChanged(focus)
}
```

Add a helper near the bottom of `focus.swift`:

```swift
@MainActor private var _lastFlashCheckAt: Date = .distantPast

@MainActor private func maybeAutoFlash(prev: FrozenFocus?, curr: LiveFocus) {
    let cfg = config.focusFlash
    guard cfg.enabled else { return }

    let now = Date()
    let secondsSincePrev = prev == nil ? .infinity : now.timeIntervalSince(_lastFlashCheckAt)
    _lastFlashCheckAt = now

    let prevWs = prev?.workspaceName
    let currWs = curr.workspace?.name
    let prevApp = prev?.windowOrNil?.app.id  // adjust to actual property names
    let currApp = curr.windowOrNil?.app.id

    if shouldAutoFlash(
        mode: cfg.mode,
        prevWorkspace: prevWs,
        currWorkspace: currWs,
        prevAppId: prevApp,
        currAppId: currApp,
        secondsSincePrev: secondsSincePrev,
        idleThreshold: cfg.idleThresholdSeconds,
    ) {
        FocusFlashController.shared.flash(window: curr.windowOrNil)
    }
}
```

**Investigate before completing:** the property accessors above (`prev?.workspaceName`, `curr.workspace?.name`, `windowOrNil?.app.id`) are guesses. Open `Sources/AppBundle/focus.swift` and `Sources/AppBundle/model/Focus.swift` (or wherever `FrozenFocus` and `LiveFocus` are defined) and use the actual property names. Adjust the helper to match.

**Step 5: Run tests**

Run: `./build.sh`
Expected: all 10 predicate tests pass; existing focus tests still pass.

**Step 6: Commit**

```bash
git add Sources/AppBundle/FocusFlashPredicate.swift \
        Sources/AppBundle/focus.swift \
        Sources/AppBundleTests/FocusFlashPredicateTest.swift
git commit -m "Plumb auto-flash hook into focus-change callback"
```

---

### Task 7: Wire `FlashFocusCommand` to the controller

**Files:**
- Modify: `Sources/AppBundle/command/impl/FlashFocusCommand.swift`

**Step 1: Replace the no-op body**

```swift
struct FlashFocusCommand: Command {
    let args: FlashFocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        await MainActor.run {
            FocusFlashController.shared.flash(window: focus.windowOrNil)
        }
        return true
    }
}
```

**Investigate before completing:** confirm whether `Command.run` is already `@MainActor` (in which case the wrapper is unnecessary), and whether `focus` is the right global-style accessor or there's a specific way to get current focus inside a command. Look at `ModeCommand.swift` and other zero-arg commands for the established pattern.

**Step 2: Build & test**

Run: `./build.sh`
Expected: tests pass.

**Step 3: Commit**

```bash
git add Sources/AppBundle/command/impl/FlashFocusCommand.swift
git commit -m "Wire flash-focus command to FocusFlashController"
```

---

### Task 8: Documentation

**Files:**
- Modify: `docs/config-examples/default-config.toml` (add `[focus-flash]` example)
- Create or modify: `docs/airlock-flash-focus.adoc` (command help) — see investigation note in Task 3
- Modify: `docs/guide.adoc` (mention focus-flash under workspace/focus features) — find the right section
- Modify: `README.md` if "key features" should mention it

**Step 1: Add the config example**

Append to `docs/config-examples/default-config.toml`:

```toml
[focus-flash]
enabled = true
mode = "cross-workspace"  # one of: every, cross-workspace, cross-app, idle, off
idle-threshold-seconds = 10
color = "0xff00ff00"
width = 6.0
pop-distance = 10.0
duration-ms = 400
```

**Step 2: Add command docs**

If the project uses generated `*_help_generated.swift` from `.adoc` files, create `docs/airlock-flash-focus.adoc` modeled on `docs/airlock-mode.adoc` and re-run whatever generation step exists. If no such pipeline, replace the placeholder constant in `Sources/Common/cmdArgs/impl/FlashFocusCmdArgs.swift` with the real help string.

Find the generation script:

```bash
grep -rn "_help_generated" Sources/ | head
ls dev-docs/ docs/ 2>/dev/null
```

**Step 3: Add a note to README/guide**

In `README.md` "Key features" section, add (one bullet):

> Optional **focus flash** — pulsing outline draws the eye to the focused window after workspace switches and other cross-context jumps. Configurable, off-able.

Skip if it doesn't fit the README voice — this is optional.

**Step 4: Commit**

```bash
git add docs/ README.md Sources/Common/cmdArgs/impl/FlashFocusCmdArgs.swift
git commit -m "Document [focus-flash] config and flash-focus command"
```

---

### Task 9: Build, manual smoke test

**Step 1: Full build + test**

Run: `./build.sh`
Expected: clean build, all tests pass.

**Step 2: Run the app**

Per `CLAUDE.md`, `./deploy.sh` only when explicitly asked — so don't run it as part of the plan. Instead, ask the user to manually deploy and verify before merging:

> Manual verification checklist for the user:
> 1. `./deploy.sh`
> 2. Default config (or empty `[focus-flash]` table): switch workspaces with cmd-1 / cmd-2 etc. — green outline should pulse on the focused window.
> 3. Cmd-tab within a single workspace: no flash (cross-workspace mode is the default).
> 4. Bind `flash-focus` to a hotkey (e.g. `alt-shift-f`) and trigger: outline should pulse on the current window.
> 5. Set `mode = "every"` and verify cmd-tab now also flashes.
> 6. Set `enabled = false` and verify no flash from any source.
> 7. Set `enabled = true, mode = "off"` and verify auto-flash silent but `flash-focus` hotkey still works.
> 8. Multi-monitor: focus a window on monitor 2, verify outline appears on monitor 2 (not monitor 1).
> 9. Open a native-fullscreen app (e.g. Safari fullscreen), focus it, verify no errors / no broken state. (Flash itself may be skipped — that's expected.)

**Step 3: Push branch**

```bash
git push -u origin focus-flash
```

**Step 4: Open PR**

```bash
gh pr create --repo jss367/Airlock --base main \
  --title "Add focus-flash: pulsing outline indicator on focused window" \
  --body "$(cat <<'EOF'
## Summary

Adds a transient pulsing-outline indicator on the focused window. Solves the
"where did focus just land?" problem after workspace switches, where static
indicators (e.g. JankyBorders) only help if you're already looking near the window.

- New `[focus-flash]` config table (`enabled`, `mode`, color, width, etc.).
- New `flash-focus` built-in command for hotkey-triggered flash.
- Auto-flash defaults to `mode = "cross-workspace"` — quiet during normal work,
  fires on workspace jumps. Can be set to `every` / `cross-app` / `idle` / `off`.
- Master `enabled = false` disables both auto and the hotkey command.

Design doc: `docs/plans/2026-05-01-focus-flash-design.md`

## Test plan

- [x] Unit: config parsing (5 tests for `[focus-flash]` defaults, full config, invalid mode, invalid color)
- [x] Unit: color hex parser (5 tests)
- [x] Unit: auto-flash predicate (10 tests covering each mode + edge cases)
- [x] Unit: `flash-focus` command parses
- [ ] Manual: smoke test per checklist in the plan

## Behavior change on upgrade

`mode = "cross-workspace"` is the default, so existing users will see the flash
fire on workspace switches the first time they launch the new build. To opt out:
```toml
[focus-flash]
enabled = false  # or: mode = "off"
```
EOF
)"
```

---

## Out of Scope (do not implement)

- Per-mode color (e.g. distinct color for hotkey-triggered vs auto-flash).
- Sound on flash.
- Multiple simultaneous flashes (across monitors when focus splits).
- A GUI for configuration (project values explicitly forbid this).
- Inverse-spotlight or sonar-ring animation styles.
- Custom animation easing curves beyond `easeOut`.
