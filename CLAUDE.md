# Claude Code Instructions

## Design Principles

- **Workspace isolation is inviolable.** The user should never leave their current workspace unless they explicitly ask to (e.g. via a workspace-switch keybinding). Cmd+Tab cycles between apps within the same workspace. Cmd+` cycles between windows of the same app within the same workspace. Focus stealing from other workspaces is blocked by default.

## Workflow

- Always create a PR for any code changes. Do not commit directly to `main`.
- Create a new branch from `main` for each piece of work. Use the naming convention `claude/<short-description>`.
- After making code changes, build and deploy the app by running `./deploy.sh`.
- If the build fails, fix the issue before creating the PR.
- PR against `main`.

## Build & Deploy

- This is a Swift project built with Xcode (`Airlock.xcodeproj`).
- `./deploy.sh` builds a Release build, copies it to `/Applications/Airlock.app`, and launches it.
- Use `-derivedDataPath .xcode-build` to keep build artifacts local to the repo.
- Use `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO` since we don't have signing set up.
