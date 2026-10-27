public import Foundation

/// Editor-facing state belongs to one plugin session, independently of its process transport.
final class PluginEditorIntegration: @unchecked Sendable {
    let workbench = WorkbenchSession()
    let jobs = PluginServiceJobs()
    var workspaceCatalog: [String: String] = [:]
    var workspaceResolver: (@MainActor @Sendable (String) throws -> EditorApplication)?
    var peers: (@MainActor @Sendable () -> [EditorApplication])?
    var installations: PluginInstallations?
}
