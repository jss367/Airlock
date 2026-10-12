import AppKit
import Common

struct ReloadConfigCommand: Command {
    let args: ReloadConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        var stdout = ""
        let isOk = try await reloadConfig(args: args, stdout: &stdout)
        if !stdout.isEmpty {
            io.out(stdout)
        }
        return isOk
    }
}

@MainActor func reloadConfig(forceConfigUrl: URL? = nil) async throws -> Bool {
    var devNull = ""
    return try await reloadConfig(forceConfigUrl: forceConfigUrl, stdout: &devNull)
}

@MainActor func reloadConfig(
    args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []),
    forceConfigUrl: URL? = nil,
    stdout: inout String,
) async throws -> Bool {
    try await reloadConfig(args: args, forceConfigUrl: forceConfigUrl, source: .user, stdout: &stdout)
}

/// Loads the default config after the user's config at `userConfigUrl` failed to load at startup.
/// Leaves the login item alone: the default `start-at-login = false` says nothing about what the user wants.
/// Keeps watching the user's file whatever its `auto-reload-config` says, which is unknown while it doesn't
/// parse, so saving a fix applies it. `userConfigUrl` is nil when there is no single user file to watch
@MainActor func loadDefaultConfigAfterFailure(userConfigUrl: URL?, stdout: inout String) async throws -> Bool {
    try await reloadConfig(forceConfigUrl: defaultConfigUrl, source: .defaultsAfterFailure(userConfigUrl: userConfigUrl), stdout: &stdout)
}

/// Reloads the config for a UI action or the config file watcher. Works while Airlock is paused too.
/// The reload keeps the paused state, so the new config lands in `config` and takes effect on resume
@MainActor func reloadConfigFromUi(_ event: RefreshSessionEvent) async throws {
    if let token: RunSessionGuard = .isServerEnabled {
        try await runLightSession(event, token) { _ = try await reloadConfig() }
    } else {
        // No session while paused. Its focus sync would trust the stale focus cache and
        // pull focus back to whatever window was focused before the pause
        _ = try await reloadConfig()
        // The session would have republished TrayMenuModel. Do it here so the menu redraws
        TrayMenuModel.shared.objectWillChange.send()
    }
}

private enum ConfigSource {
    case user
    case defaultsAfterFailure(userConfigUrl: URL?)
}

@MainActor private func reloadConfig(
    args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []),
    forceConfigUrl: URL?,
    source: ConfigSource,
    stdout: inout String,
) async throws -> Bool {
    let result: Bool
    switch readConfig(forceConfigUrl: forceConfigUrl) {
        case .success(let (parsedConfig, url)):
            if !args.dryRun {
                resetHotKeys()
                config = parsedConfig
                configUrl = url
                if case .defaultsAfterFailure(let userConfigUrl) = source {
                    failedUserConfigUrl = userConfigUrl
                } else {
                    failedUserConfigUrl = nil
                }
                // Release the old quick-switcher key before activateMode registers the new bindings. macOS refuses
                // a second registration of a key this process holds, and HotKey ignores that failure, so a key
                // moved from the quick switcher to a binding would stay dead until the next reload.
                // The parser rejects a new quick-switcher key that collides with any binding
                registerQuickSwitcherHotkey()
                // The new config may have dropped the active mode. Staying in it would disable every hotkey.
                // nil means Airlock is disabled, which must stay that way
                try await activateMode(activeMode.map { config.modes[$0] != nil ? $0 : mainModeId })
                if case .user = source {
                    // The fallback keeps the message explaining why the user's config didn't load
                    MessageModel.shared.message = nil
                    syncStartAtLogin()
                }
            }
            result = true
        case .failure(let msg):
            stdout.append(msg)
            if !args.noGui {
                Task { @MainActor in
                    MessageModel.shared.message = Message(description: "Airlock Config Error", body: msg)
                }
            }
            result = false
    }
    if !args.dryRun {
        syncConfigFileWatcher()
    }
    return result
}
