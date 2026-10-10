import Foundation
import PluginRuntime

struct PendingPluginApproval {
    var packageURL: URL
    var inspection: PluginInspection
}

/// Plugin session state: the host connection, execution bindings, authorization
/// storage, the pending approval and components enabled plugins declared.
///
/// Grouped here so the application object does not accumulate plugin fields.
final class PluginSession: @unchecked Sendable {
    var hostClient: PluginHostProcessClient?
    var bindings: [String: PluginExecutionBinding] = [:]
    let authorizationStore: EditorPluginAuthorizationStore
    var pendingApproval: PendingPluginApproval?
    let components = PluginComponentStore()

    init(projectDirectory: String) {
        authorizationStore = EditorPluginAuthorizationStore(projectDirectory: projectDirectory)
    }

    func stop() {
        hostClient?.stop()
        hostClient = nil
        bindings.removeAll()
        pendingApproval = nil
    }
}
