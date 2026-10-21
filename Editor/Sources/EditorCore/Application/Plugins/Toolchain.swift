import Foundation
import PluginRuntime

extension EditorApplication {
    @MainActor
    public func selectSwiftToolchain(path: String?) async throws {
        guard !workstation.scripts.snapshot.toolchainActivity.isBusy else { throw SwiftToolchainError.installationInProgress }
        try await activateSwiftToolchain(path: path)
    }

    @MainActor
    private func activateSwiftToolchain(path: String?) async throws {
        guard !pluginSession.isUpdating else { throw EditorPluginCapabilityError.pluginUpdateInProgress }
        let previousBinding = pluginSession.bindings[PluginLanguageService.pluginID]
        try await workstation.scripts.configureSwiftToolchain(path: path, activate: { [self] in
            try Task.checkCancellation()
            try await mountSwiftToolchainPlugin()
        }, recover: { [self] in
            try await restoreSwiftToolchainPlugin(previousBinding)
        })
    }

    @MainActor
    private func mountSwiftToolchainPlugin() async throws {
        guard try !BundledPlugins.disabled(in: projectDirectory).contains(PluginLanguageService.pluginID) else { return }
        if pluginSession.bindings[PluginLanguageService.pluginID] != nil {
            try await reloadPlugin(id: PluginLanguageService.pluginID)
        } else {
            let client = try resolvedPluginHostClient()
            let url = BundledPlugins.swiftSupport
            let inspection = try await Task.detached { try client.inspectPlugin(at: url) }.value
            try await enablePlugin(at: url, authorization: PluginAuthorizationRecord(inspection: inspection))
        }
    }

    @MainActor
    private func restoreSwiftToolchainPlugin(_ binding: PluginExecutionBinding?) async throws {
        let pluginID = PluginLanguageService.pluginID
        guard try !BundledPlugins.disabled(in: projectDirectory).contains(pluginID) else { return }
        if let binding {
            if pluginSession.bindings[pluginID] != nil {
                try await reloadPlugin(id: pluginID)
            } else {
                try await enablePlugin(at: URL(fileURLWithPath: binding.pluginPath), authorization: binding.authorization)
            }
        } else if pluginSession.bindings[pluginID] != nil {
            do {
                try await disablePlugin(id: pluginID)
            } catch {
                try BundledPlugins.setEnabled(true, id: pluginID, in: projectDirectory)
                throw error
            }
            try BundledPlugins.setEnabled(true, id: pluginID, in: projectDirectory)
        }
    }

    @MainActor
    public func installSwiftToolchain(version: String, confirmed: Bool) async throws {
        guard !workstation.scripts.snapshot.toolchainActivity.isBusy else { throw SwiftToolchainError.installationInProgress }
        guard confirmed else { throw SwiftToolchainError.confirmationRequired }
        let scripts = workstation.scripts
        let installation = SwiftToolchainInstallation()
        let generation = scripts.beginToolchainActivity(.installation(.downloading(receivedBytes: 0, totalBytes: nil)))
        do {
            let toolchain = try await installation.install(version: version, confirmed: confirmed) { progress in
                switch progress {
                case .completed, .cancelled, .failed: break
                default:
                    Task { @MainActor in scripts.reportToolchainActivity(.installation(progress), generation: generation) }
                }
            }
            try Task.checkCancellation()
            try await activateSwiftToolchain(path: toolchain.rootURL.path)
        } catch is CancellationError {
            _ = scripts.beginToolchainActivity(.installation(.cancelled))
            throw CancellationError()
        } catch {
            _ = scripts.beginToolchainActivity(.failed(error.localizedDescription))
            throw error
        }
    }
}
