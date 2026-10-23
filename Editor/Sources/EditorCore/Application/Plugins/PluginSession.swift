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
    private let hostLock = NSLock()
    private var host: PluginHostProcessClient?
    var hostClient: PluginHostProcessClient? {
        get { hostLock.withLock { host } }
        set { hostLock.withLock { host = newValue } }
    }
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
    var aiProvider: AIProviderDescriptor?
    var packageMonitor: PluginPackageMonitor?
    var bundledStartup: Task<Void, Never>?
    @MainActor var projection: Task<Void, Error>?

    init(projectDirectory: String) throws {
        authorizationStore = EditorPluginAuthorizationStore(projectDirectory: projectDirectory)
        let registry = CapabilityRegistry.aiDefault
        manager = PluginManager(registrar: try contributions.registrar(),
            hostCapabilities: Dictionary(uniqueKeysWithValues: registry.allVerbs().compactMap { id in
                registry.descriptor(for: id).map { (id, $0.version) }
            }))
        runtime = PluginRuntimeAccess(contributions: contributions)
    }

    func stop() {
        bundledStartup?.cancel()
        bundledStartup = nil
        packageMonitor?.stop()
        packageMonitor = nil
        manager.stop()
        hostClient = nil
        pendingApproval = nil
    }
}
