import Foundation
import PluginRuntime

public enum PluginCommandError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case documentTooLarge

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The plugin that provides this is no longer enabled."
        case .documentTooLarge: "The document exceeds the 64 KiB limit for plugin views."
        }
    }
}

extension EditorApplication {
    /// Commands, panels and views of the enabled packages.
    public var workbenchCatalog: WorkbenchCatalog { pluginSession.workbench.catalog }

    /// The observable source of ``workbenchCatalog``.
    public var workbench: WorkbenchSession { pluginSession.workbench }

    /// The panel that holds the agent conversation, while an agent is enabled.
    public var agentPanelID: String? { isAgentEnabled ? workbenchCatalog.panel(view: .agent)?.id : nil }

    /// Called on the main actor whenever a package adds or removes a command or panel.
    public func setWorkbenchChangeHandler(_ handler: @escaping @MainActor () -> Void) {
        pluginSession.workbench.onChange = handler
    }

    /// Runs a package's command, then refreshes the package's panels. The
    /// result says what to show; carrying it out is the shell's job.
    @MainActor
    public func runPluginCommand(pluginID: String, name: String,
                                 arguments: PluginJSON? = nil) async throws -> PluginCommandResult {
        let catalog = workbenchCatalog
        guard let command = catalog.command(pluginID: pluginID, name: name) else { throw PluginCommandError.unavailable }
        let encoded = try arguments.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "{}"
        defer { pluginSession.workbench.refreshContent(of: pluginID) }
        let text = try await readEntryPoint(pluginID: pluginID, entryPoint: command.entryPoint,
                                            event: "onCommand:" + name,
                                            input: ["command": name, "arguments": encoded])
        return try PluginCommandResult(json: text, panels: catalog.panelIDs(pluginID: pluginID))
    }

    /// The content state of a panel its package describes.
    @MainActor
    public func panelState(for panel: ContributedPanel) -> PluginPanelState {
        pluginSession.workbench.state(for: .panel(panel)) { [weak self] in
            guard let self, let entryPoint = panel.entryPoint,
                  self.workbenchCatalog.panel(id: panel.id) == panel else { throw PluginCommandError.unavailable }
            let text = try await self.readEntryPoint(pluginID: panel.pluginID, entryPoint: entryPoint,
                                                     event: "onView:" + panel.id, input: ["panel": panel.id])
            return try PanelModel(json: text, commands: self.workbenchCatalog.commandIDs(pluginID: panel.pluginID))
        }
    }

    /// The content state of a document shown in a package's view. Each description
    /// reads the document's current text, saved or not.
    @MainActor
    public func documentViewState(for view: ContributedDocumentView, path: String) -> PluginPanelState {
        pluginSession.workbench.state(for: .document(view, path: path)) { [weak self] in
            guard let self, self.workbenchCatalog.documentViews.contains(view),
                  let document = self.workstation.documents.snapshot.documents.first(where: { $0.path == path }) else {
                throw PluginCommandError.unavailable
            }
            guard document.text.utf8.count <= DocumentViewContribution.maximumTextBytes else {
                throw PluginCommandError.documentTooLarge
            }
            let text = try await self.readEntryPoint(pluginID: view.pluginID, entryPoint: view.entryPoint,
                                                     event: "onView:" + view.id,
                                                     input: ["path": path, "text": document.text])
            return try PanelModel(json: text, commands: self.workbenchCatalog.commandIDs(pluginID: view.pluginID))
        }
    }

    /// Workbench and context entry points return a string; the read result carries it as JSON.
    @MainActor
    func readEntryPoint(pluginID: String, entryPoint: String, event: String,
                        input: [String: String]) async throws -> String {
        let (binding, client) = try await pluginSession.runtime.resolve(pluginID, event: event)
        let data = try JSONEncoder().encode(input)
        let capabilityID = pluginID + "." + entryPoint
        let result = try await Task.detached(priority: .userInitiated) {
            try client.prepareCapability(binding: binding, capabilityID: capabilityID, input: data, querySnapshot: nil)
        }.value
        guard case let .read(payload) = result, let text = try? JSONDecoder().decode(String.self, from: payload) else {
            throw PluginWorkbenchResultError.invalidCommandResult
        }
        return text
    }
}
