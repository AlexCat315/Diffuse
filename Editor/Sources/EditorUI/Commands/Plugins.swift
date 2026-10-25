internal import EditorCore
internal import GuavaUI
internal import PluginRuntime

/// Runs a package's command and carries out what it returns: a notification,
/// a failure, or one of the package's panels brought forward.
enum PluginCommandRunner {
    static func run(pluginID: String, name: String, arguments: PluginJSON? = nil, app: EditorApplication) {
        Task { @MainActor in
            let notifications = EditorNotifications.of(app)
            do {
                let result = try await app.runPluginCommand(pluginID: pluginID, name: name, arguments: arguments)
                if let error = result.error {
                    notifications.post(error, id: pluginID, tone: .danger, duration: nil)
                } else if let message = result.message {
                    notifications.post(message, id: pluginID)
                }
                if let panel = result.panel { app.showPanel(panel) }
            } catch {
                notifications.post(error.localizedDescription, id: pluginID, tone: .danger, duration: nil)
            }
        }
    }
}
