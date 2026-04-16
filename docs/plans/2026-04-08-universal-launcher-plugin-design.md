# Airlock Plugin for Universal Launcher

## Summary

Create a V1 plugin in the Universal Launcher (UL) codebase that makes all app launches workspace-aware via Airlock. When a user selects an app in UL, the plugin runs `airlock summon-app "<app name>"` instead of a normal launch, so the app lands in the current Airlock workspace.

## Separation of Concerns

- **Universal Launcher**: App discovery, search/filter UI, user interaction. The single place to launch apps.
- **Airlock**: Workspace management, window focus, Cmd+Tab/Cmd+` cycling. Controls which workspace you're on.
- **Plugin (this work)**: Bridges the two. Routes UL app launches through Airlock's `summon-app` command.

## How `summon-app` Works

Airlock's `summon-app` command already handles every scenario:
- App running on another workspace: moves it to current workspace and focuses it
- App running on current workspace: focuses it
- App running but no windows: launches a new instance
- App not running: launches it

## Plugin Design

### File

`plugins/airlock/index.tsx` in the Universal Launcher codebase.

### Command

Single command, keyword `open`.

### Lifecycle

1. **`isAuthenticated()`** — returns `true` only on macOS (Airlock is macOS-only)
2. **`hydrateLaunchCommander()`** — calls `electronAPI.pollInstalledApplications()`, caches the app list
3. **`getArgSuggestions()`** — filters cached apps by user input, returns matches with app icons
4. **`submitCommand()`** — runs `airlock summon-app "<app name>"` via `electronAPI.exec()`. Falls back to `open -a "<app name>"` if Airlock isn't running.

### Registration

Import in `plugins/index.ts` and add `airlock: AirlockPlugin` to the plugins object.

### No Server-Side Code

Everything runs client-side via Electron shell execution.

### Fallback

If Airlock isn't running (exec fails), fall back to `open -a "<app name>"` for a normal macOS launch.

## Data Flow

```
User types "open chr..."
    -> hydrateLaunchCommander() has cached installed apps list
    -> getArgSuggestions() filters to ["Google Chrome", "ChromeDriver"]
    -> User selects "Google Chrome"
    -> submitCommand() runs: airlock summon-app "Google Chrome"
    -> If Airlock not running, falls back to: open -a "Google Chrome"
    -> Hide launcher, show notification
```
