import AIRuntime
import Foundation
import PluginRuntime

extension EditorApplication {
    /// Re-mounts an enabled plugin whose package still satisfies its stored
    /// authorization: unload + load on the same host generation, then refresh
    /// its component declarations. Any code, contract, permission, schema, or
    /// requirement change fails closed and requires re-authorization through
    /// the management flow.
    @MainActor
    public func reloadPlugin(id pluginID: String) async throws {
        do { try await pluginSession.manager.reload(id: pluginID) }
        catch PluginAuthorizationError.noLongerValid {
            throw EditorPluginCapabilityError.pluginAuthorizationStale(pluginID)
        } catch { try? await synchronizePlugins(); throw error }
        try await synchronizePlugins()
    }

    /// Starts polling enabled plugin packages for changes. A byte-identical
    /// build is remounted automatically; anything else is surfaced for
    /// re-authorization. Watching never authorizes on its own.
    @MainActor
    public func startWatchingPluginPackages(interval: TimeInterval = 1.0) {
        guard pluginSession.packageMonitor == nil else { return }
        let monitor = PluginPackageMonitor()
        pluginSession.packageMonitor = monitor
        monitor.start(interval: interval) { [weak self] pluginIDs in
            Task { @MainActor [weak self] in
                await self?.handleWatchedPluginChanges(pluginIDs)
            }
        }
        monitor.setPackages(pluginPackageURLs())
        logConsole("Watching enabled plugin packages for changes")
    }

    @MainActor
    public func stopWatchingPluginPackages() {
        pluginSession.packageMonitor?.stop()
        pluginSession.packageMonitor = nil
    }

    @MainActor
    private func handleWatchedPluginChanges(_ pluginIDs: [String]) async {
        for pluginID in pluginIDs {
            // A poll observed the bytes once. Keep that observation until an
            // in-flight mount finishes, otherwise a busy rejection would lose
            // the change permanently when the next poll sees the same files.
            while pluginSession.isUpdating, !isShuttingDown,
                  pluginSession.packageMonitor != nil {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !isShuttingDown, pluginSession.packageMonitor != nil else { return }
            guard let pluginURL = pluginPackageURLs()[pluginID] else { continue }
            if pluginSession.pendingApproval?.inspection.manifest.id == pluginID { continue }
            do {
                try await reloadPlugin(id: pluginID)
                logConsole("Reloaded changed plugin", detail: pluginID)
            } catch let error as EditorPluginCapabilityError {
                if case .pluginAuthorizationStale = error {
                    logConsole("Plugin changed on disk; authorization required",
                               severity: .warning,
                               detail: pluginID)
                    await inspectPluginForManagement(
                        at: pluginURL
                    )
                } else {
                    logConsole("Plugin reload failed",
                               severity: .warning,
                               detail: "\(pluginID): \(error.localizedDescription)")
                }
            } catch {
                logConsole("Plugin reload failed",
                           severity: .warning,
                           detail: "\(pluginID): \(error.localizedDescription)")
            }
        }
    }

    /// Package URLs of the currently enabled plugins, keyed by plugin id.
    func pluginPackageURLs() -> [String: URL] {
        let enabled = Set(pluginSession.manager.enabledManifests.keys)
        return pluginSession.manager.packageURLs.filter { enabled.contains($0.key) }
    }

    /// Reloads an enabled plugin from its package without leaving the Editor.
    /// A package that no longer matches its stored authorization is surfaced
    /// for review instead of being mounted.
    @MainActor
    public func reloadPluginFromManagement(id pluginID: String) async {
        do {
            try await reloadPlugin(id: pluginID)
            publishPluginManagement(phase: .idle,
                                    candidate: store.state.assistant.pluginManagement.candidate,
                                    message: "Reloaded plugin '\(pluginID)'.")
        } catch let error as EditorPluginCapabilityError {
            if case .pluginAuthorizationStale = error,
               let pluginURL = pluginPackageURLs()[pluginID] {
                await inspectPluginForManagement(
                    at: pluginURL
                )
            } else {
                publishPluginManagement(phase: .failed,
                                        candidate: store.state.assistant.pluginManagement.candidate,
                                        message: Self.pluginManagementErrorMessage(error))
            }
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: store.state.assistant.pluginManagement.candidate,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

}
