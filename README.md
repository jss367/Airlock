# Airlock Beta [![Build](https://github.com/jss367/Airlock/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/jss367/Airlock/actions/workflows/build.yml)

Airlock is an i3-like tiling window manager for macOS

Docs:
- [Airlock Guide](https://github.com/jss367/Airlock)
- [Airlock Commands](https://github.com/jss367/Airlock)
- [Airlock Goodies](https://github.com/jss367/Airlock)

## Key features

- Tiling window manager based on a [tree paradigm](https://github.com/jss367/Airlock)
- [i3](https://i3wm.org/) inspired
- Fast workspaces switching without animations and without the necessity to disable SIP
- Airlock employs its [own emulation of virtual workspaces](https://github.com/jss367/Airlock) instead of relying on native macOS Spaces due to [their considerable limitations](https://github.com/jss367/Airlock)
- Plain text configuration (dotfiles friendly). See: [default-config.toml](https://github.com/jss367/Airlock)
- CLI first (manpages and shell completion included)
- Doesn't require disabling SIP (System Integrity Protection)
- [Proper multi-monitor support](https://github.com/jss367/Airlock) (i3-like paradigm)
- Workspace-aware app launching via keybindings. Unlike standalone hotkey tools (e.g. Karabiner-Elements, skhd), Airlock knows which workspace is focused, so launched apps can be placed on the correct workspace automatically

## Installation

Download the latest release from the [releases page](https://github.com/jss367/Airlock/releases).

In multi-monitor setup please make sure that monitors [are properly arranged](https://github.com/jss367/Airlock).

> [!NOTE]
> By using Airlock, you acknowledge that it's not [notarized](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).
>
> Notarization is a "security" feature by Apple.
> You send binaries to Apple, and they either approve them or not.
> In reality, notarization is about building binaries the way Apple likes it.
>
> I don't have anything against notarization as a concept.
> I specifically don't like the way Apple does notarization.
> I don't have time to deal with Apple.

## Project status

Very rough

## Development

A notes on how to setup the project, build it, how to run the tests, etc. can be found here: [dev-docs/development.md](./dev-docs/development.md)

## Project values

**Values**
- Airlock is targeted at advanced users and developers
- Keyboard centric
- Breaking changes (configuration files, CLI, behavior) are avoided as much as possible, but it must not let the software stagnate.
  Thus breaking changes can happen, but with careful considerations and helpful message.
  [Semver](https://semver.org/) major version is bumped in case of a breaking change (It's all guaranteed once Airlock reaches 1.0 version, until then breaking changes just happen)
- Airlock doesn't use GUI, unless necessarily
  - Airlock will never provide a GUI for configuration.
    For advanced users, it's easier to edit a configuration file in text editor rather than navigating through checkboxes in GUI.
  - Status menu icon is ok, because visual feedback is needed
- Provide _practical_ features. Fancy appearance features are not _practical_ (e.g. window borders, transparency, animations, etc.)
- "dark magic" (aka "private APIs", "code injections", etc.) must be avoided as much as possible
  - Right now, Airlock uses only a single private API to get window ID of accessibility object `_AXUIElementGetWindow`.
    Everything else is [macOS public accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement_h).
  - Airlock will never require you to disable SIP (System Integrity Protection).
  - The goal is to make Airlock easily maintainable, and resistant to macOS updates.

**Non Values**
- Play nicely with existing macOS features.
  If limitations are imposed then Airlock won't play nicely with existing macOS features
  (For example, Airlock doesn't acknowledge the existence of macOS Spaces, and it uses [emulation of its own workspaces](https://github.com/jss367/Airlock))
- Ricing.
  Airlock provides only a very minimal support for ricing - gaps and a few callbacks for integrations with bars.
  The current maintainer doesn't care about ricing.
  Ricing issues are not a priority, and they are mostly ignored.
  The ricing stance can change only with the appearance of more maintainers.

## macOS compatibility table

|                                                                                | macOS 13 (Ventura) | macOS 14 (Sonoma) | macOS 15 (Sequoia) | macOS 26 (Tahoe) |
| ------------------------------------------------------------------------------ | ------------------ | ----------------- | ------------------ | ---------------- |
| Airlock binary runs on ...                                                   | +                  | +                 | +                  | +                |
| Airlock debug build from sources is supported on ...                         |                    | +                 | +                  | +                |
| Airlock release build from sources is supported on ... (Requires Xcode 26+)  |                    |                   | +                  | +                |


## Tip of the day

```bash
defaults write -g NSWindowShouldDragOnGesture -bool true
```

Now, you can move windows by holding `ctrl`+`cmd` and dragging any part of the window (not necessarily the window title)

Source: [reddit](https://www.reddit.com/r/MacOS/comments/k6hiwk/keyboard_modifier_to_simplify_click_drag_of/)

## Related projects

- AeroSpace
- [Amethyst](https://github.com/ianyh/Amethyst)
- [yabai](https://github.com/koekeishiya/yabai)
