# Focus Flash — Design

**Status:** Design approved, ready for implementation plan.
**Date:** 2026-05-01

## Problem

Airlock enforces strict workspace isolation, which means focus regularly jumps to windows the user wasn't looking at — workspace switches, `summon-app`, focus-stealing-prevention overrides. Static visual indicators like JankyBorders are insufficient: they're only useful if the user is *already looking* at the window, so they don't solve "where did focus just go?" when it lands somewhere peripheral.

The user wants a transient, motion-based indicator that draws the eye to the focused window — both automatically on focus changes and on demand via a hotkey.

## Goals

- Make focus location detectable via peripheral vision.
- Trigger automatically on the focus transitions Airlock users care about (workspace jumps).
- Provide a hotkey for "where am I right now?" on demand.
- Stay fully configurable, including off.
- Compose cleanly with JankyBorders (which the user already runs).

## Non-Goals

- No persistent border / always-on outline (JankyBorders already does that).
- No ricing knobs beyond what's required for the feature to be useful (matches Airlock's stated values).
- No "focus stealing detected" badges, toast notifications, or other UI metaphors. Just the flash.
- No animation styles besides the pulsing outline (see Visual Design).

## Visual Design

**Pulsing outline.** A bright outline appears tight on the focused window's frame, expands outward by a small distance ("pop"), and fades from opacity 1 → 0 over the configured duration.

Why pulsing outline over alternatives:
- **Sonar rings** would be more attention-grabbing but feel notification-heavy.
- **Inverse spotlight** (dim everything else) is the loudest option but also the most intrusive — it takes over the entire visual field on every focus change.
- The pulsing outline is contained to the window, so even firing on every cross-workspace switch doesn't dominate the screen, while the *motion* (expansion + fade) is what triggers peripheral detection — which static color alone fails to do.

Defaults:
- color: `0xff00ff00` (matches the JankyBorders config the user landed on)
- width: 6.0 pt
- pop-distance: 10.0 pt outward expansion during the pulse
- duration: 400 ms

## Trigger Modes

A single configurable `mode` field controls auto-flash behavior:

| Mode               | Fires when                                                                  |
| ------------------ | --------------------------------------------------------------------------- |
| `every`            | Any focus change.                                                           |
| `cross-workspace`  | **Default.** Focus moves to a window on a different workspace than before.  |
| `cross-app`        | Focus moves to a window of a different application.                         |
| `idle`             | Focus changes after `idle-threshold-seconds` of no focus events.            |
| `off`              | Auto-flash disabled. Hotkey command still works.                            |

`cross-workspace` is the default because it lines up with what makes Airlock distinct: workspace jumps are exactly when users lose track of focus. Other modes are opt-in for users with different pain points.

## Hotkey Command

New built-in command: **`flash-focus`**.

- Triggers a flash on the currently focused window regardless of `mode`.
- Bindable via the standard binding syntax:
  ```toml
  [mode.main.binding]
  alt-shift-f = 'flash-focus'
  ```
- No-op if no window is focused. No error message.
- Works even when `mode = "off"` (so users can opt out of auto-flash but keep the hotkey).
- Disabled only when `enable = false` (the master switch).

## Configuration Schema

New top-level table `[focus-flash]`:

```toml
[focus-flash]
# Master switch. Default: true. When false, both auto-flash and the
# flash-focus command are disabled.
enable = true

# Auto-flash trigger. One of: "every", "cross-workspace", "cross-app",
# "idle", "off". Default: "cross-workspace".
mode = "cross-workspace"

# Used only when mode = "idle". Default: 10.
idle-threshold-seconds = 10

# Visual.
color = "0xff00ff00"   # AARRGGBB
width = 6.0            # pt
pop-distance = 10.0    # pt outward expansion during the pulse
duration-ms = 400      # total animation length
```

Naming follows the established `[quick-switcher]` table convention. An empty `[focus-flash]` table is valid and means "use all defaults."

## Default Behavior on Upgrade

**Auto-on, cross-workspace mode, by default.** Existing users will see the flash on workspace switches the first time they launch the new build. This is an intentional behavior change — discoverability of the feature outweighs the surprise factor in this case, and the default mode (cross-workspace) is chosen specifically to be quiet during normal in-workspace work.

Release notes should call this out and document the off switch (`enable = false` or `mode = "off"`).

## Edge Cases

| Case                                                              | Behavior                                                                  |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Rapid focus changes (new flash while previous still animating)    | Cancel old, start new on new window. Stale flashes don't pile up.         |
| Multi-monitor                                                     | Overlay panel created on screen containing the focused window's frame.    |
| Window straddling two screens                                     | Use screen containing window center.                                      |
| macOS native fullscreen window                                    | Skip flash. Overlays can't reliably render above native fullscreen Spaces.|
| Floating / non-tiled window                                       | Flash normally — real AX window, real frame, no special-case.             |
| `macosPopupWindow` / `macosNativeHiddenAppWindow`                 | Skip flash. Not real focus targets in Airlock's model.                    |
| Window with no resolvable frame at flash time (closed/minimized)  | Silently no-op. No log spam.                                              |
| `flash-focus` invoked with no focused window                      | Silently no-op. Matches existing Airlock command convention.              |

## Architecture Sketch

- **`FocusFlashOverlay`** — borderless transparent `NSPanel` (`.nonactivatingPanel`, `.borderless`, `.hudWindow`-ish style) hosting an `NSView` with a `CAShapeLayer` that draws the outline. Animation via `CABasicAnimation` on opacity + frame for the "pop." One instance reused across flashes; resized/repositioned per fire.
- **`FocusFlashController`** — owns the overlay, exposes `flash(window:)`. Cancels any in-flight animation before starting a new one. Handles edge cases (no frame, fullscreen, popup-type windows).
- **Auto-flash hook** — listens to existing focus-change notification path in `focus.swift`. Applies the `mode` predicate (`every` / `cross-workspace` / `cross-app` / `idle`) to decide whether to call `flash(window:)`.
- **`FlashFocusCommand`** — new Airlock command implementing `flash-focus`. Calls `controller.flash(currentlyFocusedWindow)`.
- **Config parsing** — extend `parseConfig.swift` and `Config.swift` with a `FocusFlashConfig` struct mirroring the schema above. Existing `[quick-switcher]` parsing is the closest precedent to follow.

Existing infrastructure to lean on:
- `Sources/AppBundle/ui/NSPanelHud.swift` — borderless overlay panel pattern.
- `Sources/AppBundle/focus.swift` — focus tracking + `_prevFocusedWorkspaceName` state.
- The hotkey binding system already routes to commands; `flash-focus` plugs in like any other built-in command.

## Testing

- Unit tests for the `mode` predicate (`every` / `cross-workspace` / `cross-app` / `idle` / `off`) with synthetic focus-change events.
- Unit tests for `FocusFlashConfig` parsing (defaults, missing fields, invalid mode string, invalid color string).
- Manual / smoke test for the actual rendering — animation behavior is hard to assert in unit tests and the existing project doesn't snapshot UI.
- Test that `flash-focus` command is callable when `enable = true, mode = "off"` and no-op when `enable = false`.
- Test edge cases: no focused window, popup window types, closed-mid-flash window.
