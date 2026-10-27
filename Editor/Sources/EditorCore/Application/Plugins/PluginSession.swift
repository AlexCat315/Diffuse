import Foundation
import PluginRuntime
import CapabilityRuntime
import SceneRuntime

struct PendingPluginApproval {
    var packageURL: URL
    var inspection: PluginInspection
}

/// The lifecycle owner, host infrastructure and domain snapshots of one editor.
final class PluginSession: @unchecked Sendable {
    /// One host process per plugin: a fault in one plugin cannot stall or kill
    /// another. The pool is filled on first use.
    let hosts: PluginHostPool
    let manager: PluginManager
    let contributions = PluginContributions()
    let runtime: PluginRuntimeAccess
    let authorizationStore: EditorPluginAuthorizationStore
    var pendingApproval: PendingPluginApproval?
    let components = PluginComponentStore()
    var isUpdating: Bool { manager.isBusy }
    var themeRevision: UInt64?
    var providerRevision: UInt64?
    var languageRevision: UInt64?
    var aiAuthorities: [String: PluginCapabilityAuthority] = [:]
    var languages = LanguageCatalog()
    var providers = AIProviderCatalog()
    var agents = AgentCatalog.empty
    var agentRevision: UInt64?
    let workbench = WorkbenchSession()
    var workspaceCatalog: [String: String] = [:]
    var aiProvider: AIProviderDescriptor?
    var packageMonitor: PluginPackageMonitor?
    var bundledStartup: Task<Void, Never>?
    @MainActor var projection: Task<Void, Error>?
    let serviceJobs = PluginServiceJobs()
    var workspaceResolver: (@MainActor @Sendable (String) throws -> EditorApplication)?
    var peers: (@MainActor @Sendable () -> [EditorApplication])?

    init(projectDirectory: String,
         hostExecutable: @escaping @Sendable () throws -> URL,
         onHostCrash: @escaping @Sendable (String) -> Void = { _ in }) throws {
        authorizationStore = EditorPluginAuthorizationStore(projectDirectory: projectDirectory)
        hosts = PluginHostPool(executable: hostExecutable, onCrash: onHostCrash)
        let registry = CapabilityRegistry.aiDefault
        manager = PluginManager(registrar: try contributions.registrar(),
            hostCapabilities: Dictionary(uniqueKeysWithValues: registry.allVerbs().compactMap { id in
                registry.descriptor(for: id).map { (id, $0.version) }
            }))
        runtime = PluginRuntimeAccess(contributions: contributions)
    }

    func stop() {
        if Thread.isMainThread { MainActor.assumeIsolated { serviceJobs.cancelAll() } }
        else { workbench.uiQueue.schedule { [serviceJobs] in serviceJobs.cancelAll() } }
        bundledStartup?.cancel()
        bundledStartup = nil
        packageMonitor?.stop()
        packageMonitor = nil
        manager.stop()
        hosts.stopAll()
        pendingApproval = nil
    }
}
