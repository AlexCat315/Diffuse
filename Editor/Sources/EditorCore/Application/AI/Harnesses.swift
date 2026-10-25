import AIRuntime
import Foundation
import PluginRuntime

public enum AgentHarnessError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(name): "The agent runs on the \(name) harness, which is not enabled."
        }
    }
}

extension EditorApplication {
    /// The harness the active agent names, as a step function for the
    /// session, with an identity for keeping its state between turns. Nil
    /// means the built-in loop; a named harness that is not enabled is an
    /// error rather than a silent fallback.
    @MainActor
    func agentHarness() throws -> (driver: SessionHarness, id: String)? {
        guard let name = agentCatalog.agent(id: store.state.assistant.aiSettings.agentID)?.harness else { return nil }
        for package in pluginSession.contributions.harnesses.snapshot.values.map(\.value) {
            guard let harness = ((try? package.manifest.contributes.decode(AIHarnessContributionPoint.self)) ?? [])
                .first(where: { $0.id == name }) else { continue }
            let pluginID = package.manifest.id
            let driver: SessionHarness = { [weak self] turn in
                guard let self else { throw PluginManagerError.stopped }
                let text = String(decoding: try JSONEncoder().encode(turn), as: UTF8.self)
                let payload = try await self.readEntryPoint(pluginID: pluginID, entryPoint: harness.entryPoint,
                                                            event: "onAIChat", input: ["turn": text])
                return try JSONDecoder().decode(SessionHarnessStep.self, from: payload)
            }
            return (driver, pluginID + "." + name)
        }
        throw AgentHarnessError.unavailable(name)
    }
}
