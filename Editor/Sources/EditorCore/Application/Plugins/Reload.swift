import AIRuntime
import Foundation
import PluginRuntime

extension EditorApplication {
    /// Re-mounts an enabled plugin whose package still satisfies its stored
    /// authorization: unload + load on the same host generation, then refresh
    /// its component declarations. Any code, WIT, permission, schema, or
    /// requirement change fails closed and requires re-authorization through
    /// the management flow.
    @MainActor
    public func reloadPlugin(id pluginID: String) async throws {
        guard !pluginSession.isUpdating else {
            throw EditorPluginCapabilityError.pluginUpdateInProgress
        }
        pluginSession.isUpdating = true
        defer { pluginSession.isUpdating = false }
        guard let binding = pluginSession.bindings[pluginID] else {
            throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
        }
        let client = try resolvedPluginHostClient()
        let pluginURL = URL(fileURLWithPath: binding.pluginPath, isDirectory: true)
        let inspection = try await Task.detached(priority: .userInitiated) {
            try client.inspectPlugin(at: pluginURL)
        }.value
        guard binding.authorization.isStillValid(for: inspection) else {
            throw EditorPluginCapabilityError.pluginAuthorizationStale(pluginID)
        }
        let reloaded: PluginExecutionBinding
        let processContext = try pluginProcessContext(for: binding.authorization.host)
        if pluginID == PluginLanguageService.pluginID {
            dynamicScriptManager.languagePlugin.bind(nil)
            workstation.scripts.stopLanguageService()
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try client.unloadPlugin(at: pluginURL)
            }.value
            reloaded = try await Task.detached(priority: .userInitiated) {
                try client.loadPlugin(at: pluginURL, authorization: binding.authorization, processContext: processContext)
            }.value
        } catch {
            await discardAfterFailedReload(pluginID: pluginID)
            throw error
        }
        // Build the replacement executor before publishing it: a registry that
        // cannot be proven consistent must not replace the mounted generation.
        var nextBindings = pluginSession.bindings
        nextBindings[pluginID] = reloaded
        let executor: PluginCapabilityExecutor
        do {
            executor = try PluginCapabilityExecutor(
                bindings: nextBindings.values.sorted { $0.pluginID < $1.pluginID },
                invoker: client
            )
        } catch {
            try? await Task.detached(priority: .userInitiated) {
                try client.unloadPlugin(at: pluginURL)
            }.value
            await discardAfterFailedReload(pluginID: pluginID)
            throw error
        }
        let declarations = try? await Self.componentDeclarations(for: reloaded, client: client)
        guard !isShuttingDown, reloaded.hostGeneration == client.generation else {
            await discardAfterFailedReload(pluginID: pluginID)
            throw PluginAuthorizationError.noLongerValid
        }
        pluginSession.bindings = nextBindings
        pluginSession.components.set(declarations ?? [], pluginID: pluginID)
        pluginSession.components.apply(to: &scene.scene)
        await activatePluginExecutor(executor)
    }

    /// Fail-closed rollback for a reload that already unloaded the previous
    /// generation: the plugin ends up unmounted instead of half-mounted.
    @MainActor
    private func discardAfterFailedReload(pluginID: String) async {
        var removed: [PluginExecutionBinding] = []
        var pending = [pluginID]
        while let id = pending.popLast() {
            guard let binding = pluginSession.bindings[id] else { continue }
            pending += PluginRequirementResolver.dependents(
                of: id,
                providing: Set(binding.inspection.contracts.map(\.id)),
                among: pluginSession.bindings.mapValues { $0.inspection.manifest }
            )
            pluginSession.bindings.removeValue(forKey: id)
            pluginSession.components.remove(pluginID: id)
            removed.append(binding)
        }
        pluginSession.components.apply(to: &scene.scene)
        if let client = pluginSession.hostClient {
            for binding in removed.reversed() {
                let url = URL(fileURLWithPath: binding.pluginPath, isDirectory: true)
                _ = try? await Task.detached {
                    try client.unloadPlugin(at: url)
                }.value
            }
        }
        do {
            let executor = try rebuildPluginExecutor()
            await activatePluginExecutor(executor)
        } catch {
            pluginSession.bindings.removeAll()
            clearPluginComponents()
            await activatePluginExecutor(nil)
        }
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
            guard let binding = pluginSession.bindings[pluginID] else { continue }
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
                        at: URL(fileURLWithPath: binding.pluginPath, isDirectory: true)
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
        var result: [String: URL] = [:]
        for (pluginID, binding) in pluginSession.bindings {
            result[pluginID] = URL(fileURLWithPath: binding.pluginPath, isDirectory: true)
        }
        return result
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
               let binding = pluginSession.bindings[pluginID] {
                await inspectPluginForManagement(
                    at: URL(fileURLWithPath: binding.pluginPath, isDirectory: true)
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
