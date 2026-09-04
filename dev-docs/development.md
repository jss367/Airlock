# Developing Airlock

## Requirements

- macOS 13 or later.
- Xcode with Swift 6.2 or later. Select the Xcode installation with `xcode-select` if needed; command-line tools alone do not build the app bundle.
- The repository pins Swift 6.2.4 in [`.swift-version`](../.swift-version) for scripts that use [Swiftly](https://github.com/swiftlang/swiftly). `build.sh` and `deploy.sh` use the selected Xcode for the app and `swift` from your shell for tests and the command-line tool.

## Build and test

From the repository root:

```sh
./build.sh
```

This builds `Airlock.xcodeproj` in Release configuration with local ad-hoc signing, runs `swift test`, and builds the `airlock` command-line tool. It does not stop or replace the running app. App build products are in `.xcode-build/Build/Products/Release/`; use `swift build --product airlock -c release --show-bin-path` to find the command-line binary.

To run the Swift tests alone:

```sh
swift test
```

## Install and run locally

```sh
./deploy.sh
```

This stops the running Airlock app, builds and tests, replaces `/Applications/Airlock.app`, copies the command-line tool to `~/.local/bin/airlock`, and launches the app. Add `~/.local/bin` to your `PATH`. Grant Accessibility access to Airlock when prompted.

No custom signing certificate is required for `build.sh` or `deploy.sh`.

## Debugging

Open `Airlock.xcodeproj` in Xcode to build or debug the app bundle. Open `Package.swift` to work with the Swift package and its tests.

The package-based debug scripts are also available:

- `./build-debug.sh`: builds the package and creates `.debug/Airlock-Debug.app` and `.debug/airlock`.
- `./run-debug.sh`: builds and launches the debug app.
- `./run-cli.sh <arguments>`: builds and runs the debug command-line tool.

The debug app uses its own bundle identifier, `dev.airlock.debug`, and needs its own Accessibility permission. Avoid running the debug app and installed app at the same time when testing window management.

## Documentation and generated files

- `./build-docs.sh`: renders the AsciiDoc sources into `.site/` HTML and `.man/` manpages. Requires Ruby 3 or later and Bundler; dependencies are in [`Gemfile`](../Gemfile).
- `./build-shell-completion.sh`: generates shell completions in `.shell-completion/`. Requires Rust/Cargo, a modern Bash, and Fish.
- `./generate.sh`: regenerates the Xcode project, command help, version information, and shell parser. Use the flags in the script to limit regeneration when appropriate.
- `./format.sh`: formats Swift source.

Generated command help comes from `docs/airlock-*.adoc`. Update those sources rather than editing generated Swift help directly.

## Continuous integration and release packaging

[GitHub Actions](https://github.com/jss367/Airlock/actions/workflows/build.yml) runs debug and release builds. The full `./run-tests.sh` also checks formatting, generated files, command-line smoke tests, and a clean Git working tree. Commit your changes before running it; it is stricter than `./build.sh`.

`./build-release.sh --codesign-identity -` creates a locally signed release archive in `.release/`, including the app, command-line tool, manpages, and shell completions. It requires the documentation and completion dependencies above; `xcbeautify` is optional. Without the signing flag, it expects a certificate named `airlock-codesign-certificate`.

Run release packaging from a clean checkout: it regenerates files and restores tracked files with `git checkout .`. Packaging an archive does not publish a GitHub release. Airlock currently has no published releases or maintained public Homebrew tap.

## Useful tools

Use Xcode's Accessibility Inspector to inspect window accessibility properties. See [architecture notes](architecture.md) for the source layout and command implementation checklist.
