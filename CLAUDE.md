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
- Use `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO` since signing is not set up.

## Project-specific PR notes

Always use `--repo jss367/Airlock` with `gh pr create`.
