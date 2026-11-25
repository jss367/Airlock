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

This builds and tests, stops the running Airlock app only after those succeed, replaces `/Applications/Airlock.app`, links `~/.local/bin/airlock` to the command-line tool inside the app, and launches the app. Add `~/.local/bin` to your `PATH`. Grant Accessibility access to Airlock when prompted. `deploy.sh` requires one of the stable signing identities described above; `build.sh` continues to use local ad-hoc signing because it does not install its build.

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

`./build-release.sh` creates two signed archives in `.release/`. It automatically selects a stable signing identity and requires the documentation and completion dependencies above; `xcbeautify` is optional. Ad-hoc signing is rejected unless `--allow-adhoc-signing` is passed explicitly for a non-distributed CI build. With `--notarize`, Apple also notarizes the app.

- `Airlock-v<version>.zip` is for people: the app, manpages, shell completions, and licenses.
- `Airlock-app-v<version>.zip` is for in-app updates and holds only the app.

`script/bundle-app.sh` copies the command-line tool to `Airlock.app/Contents/Helpers/airlock` and signs the app, including the Sparkle helpers that Xcode doesn't sign. `deploy.sh` uses it too.

Run release packaging from a clean checkout: it regenerates files and restores tracked files with `git checkout .`. Packaging an archive does not publish a GitHub release. Published archives are available on [GitHub Releases](https://github.com/jss367/Airlock/releases). Airlock has no maintained public Homebrew tap.

### Set up a Mac for publishing

Publishing needs a Developer ID Application certificate for Airlock's release team, the GitHub CLI, and two secrets in the login keychain. Set them up once per Mac.

1. Save notarization credentials. Create an app-specific password at <https://account.apple.com>, then run the command below and enter the password when asked. To use a profile with another name, set `AIRLOCK_NOTARY_PROFILE`.

   ```sh
   xcrun notarytool store-credentials airlock-notary --team-id 3CJQ95F6MT --apple-id <your Apple ID>
   ```

2. Import the Sparkle private key if this isn't the Mac that created it. Export it on the other Mac with `generate_keys -x <file>`, import it with `generate_keys -f <file>`, and delete the file. Both need `--account dev.airlock`. The Sparkle tools are in `.xcode-build/SourcePackages/artifacts/sparkle/Sparkle/bin` after a build.

Keep a backup of the Sparkle key. `SUPublicEDKey` in `resources/Info.plist` is its public half, and installed copies of Airlock reject updates signed with another key. If the key is lost, a release that has a new `SUPublicEDKey` and the same Developer ID certificate is the way to replace it.

### Publish a release

1. Fetch the latest `origin/main`. Update `VERSION`, run `./generate.sh`, and commit the version and generated files through a pull request to `main`.
2. From the clean release commit on `main`, run `./run-tests.sh`.
3. Write the release notes to a Markdown file outside the checkout. The update window shows them too. Then run:

   ```sh
   ./publish-release.sh --notes-file /path/to/release-notes.md
   ```

   The script builds, notarizes, signs the update, pushes the tag, and creates the GitHub release. The first run asks for access to the Sparkle key; choose **Always Allow**.

4. Install the release with **Check for Updates…** in the previous version. Afterwards, verify that `airlock --version` reports the release version and the same commit for both client and server.

Create releases only with this script. Installed copies of Airlock read `appcast.xml` from the latest GitHub release, so update checks fail if that release doesn't have one. Local `deploy.sh` builds stamp the version and Git commit from the current checkout, adding `-dirty` to the commit when it contains uncommitted changes.

## Useful tools

Use Xcode's Accessibility Inspector to inspect window accessibility properties. See [architecture notes](architecture.md) for the source layout and command implementation checklist.
