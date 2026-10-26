internal import EditorCore
internal import CoveUI
internal import PluginRuntime

/// Runs a package's command. The editor carries out its effects; a failure
/// becomes a notification.
enum PluginCommandRunner {
    static func run(pluginID: String, name: String, arguments: PluginJSON? = nil, app: EditorApplication) {
        Task { @MainActor in
            do {
                try await app.runPluginCommand(pluginID: pluginID, name: name, arguments: arguments)
            } catch {
                EditorNotifications.of(app).post(error.localizedDescription, id: pluginID, tone: .danger, duration: nil)
            }
        }
    }
}
