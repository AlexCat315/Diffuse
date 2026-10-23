import Foundation
import PluginRuntime

struct PendingPluginApproval {
    var packageURL: URL
    var inspection: PluginInspection
}

struct DeclarativePluginBinding {
    let package: ValidatedPluginPackage
    let authorization: PluginAuthorizationRecord

    var inspection: PluginInspection { PluginInspection(package: package, contracts: []) }
}

/// Plugin session state: the host connection, execution bindings, authorization
/// storage, the pending approval and components enabled plugins declared.
///
/// Grouped here so the application object does not accumulate plugin fields.
final class PluginSession: @unchecked Sendable {
    var hostClient: PluginHostProcessClient?
    var bindings: [String: PluginExecutionBinding] = [:]
    /// Bundled pure-data packages enabled for this project. They never enter
    /// the process host; their contributions are registered in-process.
    var declarativePlugins: [String: DeclarativePluginBinding] = [:]
    let authorizationStore: EditorPluginAuthorizationStore
    var pendingApproval: PendingPluginApproval?
    let components = PluginComponentStore()
    let themes = EditorThemeCatalog()
    var isUpdating = false
    var packageMonitor: PluginPackageMonitor?
    var bundledStartup: Task<Void, Never>?

    init(projectDirectory: String) {
        authorizationStore = EditorPluginAuthorizationStore(projectDirectory: projectDirectory)
    }

    func stop() {
        bundledStartup?.cancel()
        bundledStartup = nil
        packageMonitor?.stop()
        packageMonitor = nil
        hostClient?.stop()
        hostClient = nil
        bindings.removeAll()
        declarativePlugins.removeAll()
        pendingApproval = nil
    }
}
