# Developing Airlock

## Requirements

- macOS 26 or later.
- Xcode with Swift 6.2 or later. Select the Xcode installation with `xcode-select` if needed; command-line tools alone do not build the app bundle.
- The repository pins Swift 6.2.4 in [`.swift-version`](../.swift-version) for scripts that use [Swiftly](https://github.com/swiftlang/swiftly). `build.sh` and `deploy.sh` use the selected Xcode for the app and `swift` from your shell for tests and the command-line tool.

## Build and test

From the repository root:

```sh
./build.sh
```

This builds `Airlock.xcodeproj` in Debug configuration with local ad-hoc signing and runs `swift test`, which also builds the `airlock` command-line tool. Debug builds are incremental, so a small edit rebuilds in seconds. It does not stop or replace the running app. The app is built as `.xcode-build/Build/Products/Debug/Airlock-Debug.app`; use `swift build --product airlock --show-bin-path` to find the command-line binary. `deploy.sh` does the Release builds, so errors that only appear with optimization show up there and in CI.

To run the Swift tests alone:

```sh
swift test
```

If a Swiftly build fails with `unknown argument: '-target-arch-variant'` after updating Xcode,
the pinned compiler may be incompatible with the selected SDK. Run `/usr/bin/swift test` to
use Xcode's matching compiler and SDK together. This does not change the repository's toolchain pin.

## Code signing

Airlock.app must be signed with the same identity across rebuilds. macOS ties Accessibility permission to the app's
designated code-signing requirement; ad-hoc signing changes that identity on every build and forces users to grant
permission again.

The release and deployment scripts prefer an installed `Developer ID Application` certificate. You can select a
specific certificate by setting `AIRLOCK_CODE_SIGN_IDENTITY` to its name or SHA-1 hash. Airlock's release Team ID is
preferred automatically; if several certificates for other teams are installed, local deployment requires an explicit
selection. Public release packaging rejects certificates that do not belong to Airlock's release team.

If you don't have a Developer ID certificate and only need local builds, create a self-signed certificate:

1. Open Keychain Access.
2. Choose Keychain Access → Certificate Assistant → Create a Certificate.
3. Name it `airlock-codesign-certificate`, select `Self Signed Root`, and use the `Code Signing` certificate type.

## Install and run locally

```sh
./deploy.sh
```

This stops the running Airlock app, builds and tests, replaces `/Applications/Airlock.app`, copies the command-line tool to `~/.local/bin/airlock`, and launches the app. Add `~/.local/bin` to your `PATH`. Grant Accessibility access to Airlock when prompted. `deploy.sh` requires one of the stable signing identities described above; `build.sh` continues to use local ad-hoc signing because it does not install its build.

## Debugging

Open `Airlock.xcodeproj` in Xcode to build or debug the app bundle. Open `Package.swift` to work with the Swift package and its tests.

The package-based debug scripts are also available:

- `./build-debug.sh`: builds the package and creates `.debug/Airlock-Debug.app` and `.debug/airlock`.
- `./run-debug.sh`: builds and launches the debug app.
- `./run-cli.sh <arguments>`: builds and runs the debug command-line tool.

The debug app uses its own bundle identifier, `dev.airlock.debug`, and needs its own Accessibility permission. Avoid running the debug app and installed app at the same time when testing window management.

Unexpected errors at asynchronous task boundaries are recorded in the macOS unified log under
the app's bundle identifier, in the `errors` category. Startup and user-action failures also show
a message with the operation and underlying error. Background window events log without opening
a message window; cancellation caused by a newer event is ignored.

In Console, filter by subsystem `dev.airlock` (or `dev.airlock.debug`) and category `errors`.
To inspect recent entries from Terminal:

```sh
log show --last 15m --style compact --predicate '(subsystem == "dev.airlock" OR subsystem == "dev.airlock.debug") AND category == "errors"'
```

The operation, error domain, and error code are visible in unified logs. Error descriptions are
private because they can contain file paths or window titles. The on-screen error message includes
the full description, domain, and error code.

## Documentation and generated files

- `./build-docs.sh`: renders the AsciiDoc sources into `.site/` HTML and `.man/` manpages. Requires Ruby 3 or later and Bundler; dependencies are in [`Gemfile`](../Gemfile).
- `./build-shell-completion.sh`: generates shell completions in `.shell-completion/`. Requires Rust/Cargo, a modern Bash, and Fish.
- `./generate.sh`: regenerates the Xcode project, command help, version information, and shell parser. Use the flags in the script to limit regeneration when appropriate.
- `./format.sh`: formats Swift source.

Generated command help comes from `docs/airlock-*.adoc`. Update those sources rather than editing generated Swift help directly.

## Continuous integration and release packaging

[GitHub Actions](https://github.com/jss367/Airlock/actions/workflows/build.yml) runs debug and release builds. The full `./run-tests.sh` also checks formatting, generated files, command-line smoke tests, and a clean Git working tree. Commit your changes before running it; it is stricter than `./build.sh`.

`./build-release.sh` creates a signed release archive in `.release/`, including the app, command-line tool, manpages, and shell completions. It automatically selects a stable signing identity and requires the documentation and completion dependencies above; `xcbeautify` is optional. Ad-hoc signing is rejected unless `--allow-adhoc-signing` is passed explicitly for a non-distributed CI build.

Run release packaging from a clean checkout: it regenerates files and restores tracked files with `git checkout .`. Packaging an archive does not publish a GitHub release. Published archives are available on [GitHub Releases](https://github.com/jss367/Airlock/releases). Airlock has no maintained public Homebrew tap.

To publish a release:

1. Fetch the latest `origin/main`. Update `VERSION`, run `./generate.sh`, and commit the version and generated files through a pull request to `main`.
2. From the clean release commit on `main`, run `./run-tests.sh` and `./build-release.sh --require-developer-id`. The archive contains universal Apple Silicon/Intel binaries with the release version and Git commit embedded. Developer ID signing gives Airlock a stable identity but does not notarize the archive; mention the lack of notarization in the release notes.
3. Create a checksum and publish the archive with the GitHub CLI:

   ```sh
   release_version="$(cat VERSION)"
   (cd .release && shasum -a 256 "Airlock-v$release_version.zip" > SHA256SUMS)
   git tag -a "v$release_version" -m "Airlock $release_version"
   git push origin "v$release_version"
   gh release create "v$release_version" \
       ".release/Airlock-v$release_version.zip" .release/SHA256SUMS \
       --repo jss367/Airlock --verify-tag --latest \
       --title "Airlock $release_version" --notes-file /path/to/release-notes.md
   ```

4. Install the packaged `Airlock.app` and `bin/airlock` together. After launching the app, verify that `airlock --version` reports the release version and the same commit for both client and server. Local `deploy.sh` builds do not regenerate version or commit information, so use the packaged files to install an exact release.

## Useful tools

Use Xcode's Accessibility Inspector to inspect window accessibility properties. See [architecture notes](architecture.md) for the source layout and command implementation checklist.
