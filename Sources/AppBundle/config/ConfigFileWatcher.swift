import Common
import Foundation

private struct ConfigFileWatcher: ~Copyable {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        fd = open(url.path, O_EVTONLY)
        if fd < 0 {
            logAppError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), operation: "Watching the configuration file")
            return nil
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main,
        )
        source.setEventHandler { MainActor.checkIsolated { onChange() } }
        source.setCancelHandler { [fd] in close(fd) }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}

@MainActor private var currentWatcher: ConfigFileWatcher? = nil
@MainActor private var debounceTask: Task<Void, Never>? = nil
@MainActor private(set) var watchedConfigUrl: URL? = nil
/// The user's config file while Airlock runs on the defaults because that file failed to load at startup.
/// It is watched until it loads, see `loadDefaultConfigAfterFailure`
@MainActor var failedUserConfigUrl: URL? = nil

private let debounceDelay: Duration = .milliseconds(200)

@MainActor func syncConfigFileWatcher() {
    currentWatcher = nil
    watchedConfigUrl = failedUserConfigUrl ?? (config.autoReloadConfig ? configUrl : nil)
    guard let watchedConfigUrl else { return }
    currentWatcher = ConfigFileWatcher(url: watchedConfigUrl) {
        debounceTask?.cancel()
        debounceTask = Task {
            await withErrorReporting("Automatically reloading configuration", userMessage: "Airlock could not automatically reload the configuration.") {
                try await Task.sleep(for: debounceDelay)
                // Reload while paused too. Each reload re-arms the watcher, and editors that replace the file (vim)
                // leave it on the deleted file, so a skipped reload would stop auto-reload until a manual one
                try await reloadConfigFromUi(.configAutoReload)
            }
        }
    }
}
