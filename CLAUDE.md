# Airlock - Claude Code Guide

## What is Airlock

macOS window manager that enforces workspace isolation. Cmd+Tab cycles apps within the same workspace. Cmd+` cycles windows of the same app within the same workspace. Focus stealing from other workspaces is blocked by default.

## Build & Test

```bash
./build.sh        # Build and run tests (does not disrupt running app)
./deploy.sh       # Release build → /Applications/Airlock.app → launch (only when asked)
```

- Swift project built with Xcode (`Airlock.xcodeproj`).
- Use `-derivedDataPath .xcode-build` to keep build artifacts local to the repo.
- `build.sh` may use ad-hoc signing because it does not install an artifact. `deploy.sh` must use a stable signing
  identity so macOS preserves Accessibility permission across rebuilds.

## Project-specific PR notes

Always use `--repo jss367/Airlock` with `gh pr create`.
