import Foundation
import PluginRuntime

public enum PluginCommandError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case documentTooLarge

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The plugin that provides this is no longer enabled."
        case .documentTooLarge: "The document is too large for plugin views."
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

    /// Shows a plugin's messages and failures; the shell installs it once.
    public func setPluginNotificationHandler(_ handler: @escaping @MainActor (_ text: String, _ isError: Bool) -> Void) {
        pluginSession.workbench.notify = handler
    }

    /// Runs a package's command, carries out its effects, then renders the
    /// package's views again.
    @MainActor
    public func runPluginCommand(pluginID: String, name: String, arguments: PluginJSON? = nil) async throws {
        let catalog = workbenchCatalog
        guard let command = catalog.command(pluginID: pluginID, name: name) else { throw PluginCommandError.unavailable }
        let encoded = try arguments.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "{}"
        defer { pluginSession.workbench.renderViews(of: pluginID) }
        let payload = try await readEntryPoint(pluginID: pluginID, entryPoint: command.entryPoint,
                                               event: "onCommand:" + name,
                                               input: ["command": name, "arguments": encoded])
        let result = try PluginCommandResult(json: payload, panels: catalog.panelIDs(pluginID: pluginID))
        applyPluginEffects(result.effects)
    }

    /// The session of a panel its package serves.
    @MainActor
    public func viewSession(for panel: ContributedPanel) -> PluginViewSession {
        viewSession(.panel(panel), entryPoint: panel.entryPoint, viewID: panel.id) { [weak self] in
            ["content": .string(self?.store.state.content.rawValue ?? "")]
        }
    }

    /// The session of a document shown in a package's view. Each call passes
    /// the document's current text, saved or not.
    @MainActor
    public func viewSession(for view: ContributedDocumentView, path: String) -> PluginViewSession {
        viewSession(.document(view, path: path), entryPoint: view.entryPoint, viewID: view.id) { [weak self] in
            guard let document = self?.workstation.documents.snapshot.documents.first(where: { $0.path == path }) else {
                throw PluginCommandError.unavailable
            }
            guard document.text.utf8.count <= DocumentViewContribution.maximumTextBytes else {
                throw PluginCommandError.documentTooLarge
            }
            return ["path": .string(path), "text": .string(document.text)]
        }
    }

    @MainActor
    private func viewSession(_ source: PluginContentSource, entryPoint: String?, viewID: String,
                             context: @escaping @MainActor () throws -> [String: PluginJSON]) -> PluginViewSession {
        pluginSession.workbench.session(for: source, invoke: { [weak self] state, event in
            guard let self, let entryPoint, source.isCurrent(in: self.workbenchCatalog) else {
                throw PluginCommandError.unavailable
            }
            let contextText = Self.json(.object(try context()))
            // Each field is a string input, bounded by the runtime.
            guard contextText.count <= 65_536 else { throw PluginCommandError.documentTooLarge }
            let payload = try await self.readEntryPoint(
                pluginID: source.pluginID, entryPoint: entryPoint, event: "onView:" + viewID,
                input: ["view": viewID, "state": state.map(Self.json) ?? "",
                        "event": try event.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "",
                        "context": contextText])
            return try PluginViewResult(json: payload, panels: self.workbenchCatalog.panelIDs(pluginID: source.pluginID))
        }, effects: { [weak self] effects in self?.applyPluginEffects(effects) })
    }

    /// Opening a file and showing a panel happen here; messages go to the shell.
    @MainActor
    func applyPluginEffects(_ effects: [UIEffect]) {
        for effect in effects {
            switch effect {
            case let .message(text): pluginSession.workbench.notify?(text, false)
            case let .error(text): pluginSession.workbench.notify?(text, true)
            case let .panel(id): showPanel(id)
            case let .open(path): openDocument(path)
            }
        }
    }

    private static func json(_ value: PluginJSON) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    /// Calls an entry point of an enabled package. A read result is the JSON
    /// the capability returned as its string.
    @MainActor
    func readEntryPoint(pluginID: String, entryPoint: String, event: String,
                        input: [String: String]) async throws -> Data {
        let (binding, client) = try await pluginSession.runtime.resolve(pluginID, event: event)
        let data = try JSONEncoder().encode(input)
        let capabilityID = pluginID + "." + entryPoint
        let result = try await Task.detached(priority: .userInitiated) {
            try client.prepareCapability(binding: binding, capabilityID: capabilityID, input: data, querySnapshot: nil)
        }.value
        guard case let .read(payload) = result else { throw PluginWorkbenchResultError.invalidCommandResult }
        return payload
    }
}
