# Airlock [![Build](https://github.com/jss367/Airlock/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/jss367/Airlock/actions/workflows/build.yml)

Airlock is a workspace and tiling window manager for macOS, built around keeping each workspace focused on its own apps and windows.

## Features

- **Workspace isolation.** With the default bindings, `Cmd+Tab` cycles apps in the current workspace and `Cmd+backtick` cycles windows of the same app in that workspace. Airlock blocks focus stealing from other workspaces.
- **Keyboard-driven tiling.** Arrange windows in tile, accordion, or floating layouts, with workspaces across multiple monitors.
- **Workspace-aware app launching.** Launch or summon apps through keybindings and the built-in app launcher.
- **Visual controls.** A quick switcher, workspace overview, keyboard visualizer with binding editing, and configurable focus flash help you navigate.
- **Plain-text configuration and scripting.** Configure Airlock with TOML and control it with the `airlock` command-line tool.
- **No need to disable System Integrity Protection.** Airlock manages windows through macOS Accessibility permissions.

## Status and installation

Airlock is in early development. Configuration and behavior may change. There are currently no published Airlock releases; build from source to try it.

Requires macOS 13 or later and Xcode with Swift 6.2 or later to build. From a checkout of this repository:

```sh
./build.sh
```

This builds the app and command-line tool and runs the tests. To install and launch your build:

```sh
./deploy.sh
```

`deploy.sh` stops any running Airlock instance, rebuilds and tests, replaces `/Applications/Airlock.app`, installs the command-line tool to `~/.local/bin/airlock`, and launches the app. Add `~/.local/bin` to your `PATH` to use `airlock` from a terminal. Grant Airlock access in **System Settings → Privacy & Security → Accessibility** when prompted.

See [development instructions](dev-docs/development.md) for toolchain setup and other build options.

## Configuration and documentation

Copy the [default configuration](docs/config-examples/default-config.toml) to `~/.airlock.toml`, or use **Open config** in the menu bar. Airlock also supports `~/.config/airlock/airlock.toml` (or `$XDG_CONFIG_HOME/airlock/airlock.toml`); keep your config in only one location. Use **Reload config** or `airlock reload-config` after editing, or enable `auto-reload-config`.

- [User guide](docs/guide.adoc): configuration, layouts, workspaces, and monitor arrangement.
- [Command reference](docs/commands.adoc): commands and examples. Run `airlock --help` or `airlock <command> --help` in a terminal.
- [Workflow examples](docs/goodies.adoc): shortcuts and scripting recipes.
- [Architecture](dev-docs/architecture.md): how the app and command-line tool fit together.

## Bugs and contributions

Report bugs and propose features in [GitHub Issues](https://github.com/jss367/Airlock/issues). See [Contributing](CONTRIBUTING.md) for what to include and how to submit a pull request.

## License and origins

Airlock is derived from [AeroSpace](https://github.com/nikitabobko/AeroSpace) and builds on its tiling and workspace foundations. It is developed independently, with a focus on workspace isolation and integrated navigation tools.

Airlock is licensed under the [MIT License](LICENSE.txt). See [dependency licenses](legal/README.md) for bundled third-party software and attribution.
