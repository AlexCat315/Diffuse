import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    // MARK: - AI settings

    /// Applies new AI settings: persists provider/model, writes the key to Keychain,
    /// and hot-swaps the Session without restart.
    @discardableResult
    public func applyAISettings(_ settings: EditorAISettings, apiKey: String) -> Bool {
        do {
            if settings.provider != .none, !apiKey.isEmpty {
                try AIKeychain.save(key: apiKey, provider: settings.provider)
            }
            guard settings.provider == .none || AIKeychain.hasKey(for: settings.provider) else {
                logConsole("AI settings were not applied",
                           severity: .error,
                           detail: "Enter an API key for \(settings.provider.displayName).")
                return false
            }
        } catch {
            logConsole("AI credentials could not be saved",
                       severity: .error,
                       detail: error.localizedDescription)
            return false
        }
        store.dispatch(.setAISettings(settings))
        store.dispatch(.clearChatHistory)
        let oldSession = session
        cancelActiveAIRequest()
        agentExecution.assistantMessageID = nil
        let newSession = Self.makeSession(
            for: settings,
            pluginCapabilityExecutor: pluginCapabilityExecutor,
            pluginQuerySnapshotProvider: makePluginQuerySnapshotProvider()
        )
        if oldSession != nil || newSession != nil {
            let worldContext = self.aiWorldContext
            let ctx = Self.workflowContext(for: store.state.workspace.mode,
                                           scriptEntries: scene.scriptCatalogEntries)
            let bus = self.observationBus
            let mem = self.contextMemoryStore
            let previousTask = pendingAISetupTask
            let projectTools = makeProjectToolExecutor()
            pendingAISetupTask = Task {
                await previousTask?.value
                await oldSession?.cancelActiveRun()
                if let newSession {
                    await newSession.setProjectToolExecutor(projectTools)
                    await newSession.replaceWorldView(await worldContext.snapshot())
                    await newSession.setObservationBus(bus)
                    await newSession.setContextMemory(mem)
                    await newSession.setWorkflowContext(ctx)
                }
            }
        }
        session = newSession
        return true
    }

    public func applyCapabilitySettings(_ settings: EditorCapabilitySettings) {
        store.dispatch(.setCapabilitySettings(settings))
        intentCoordinator.configureCapabilityPlanner(
            Self.makeCapabilityInvocationPlanner(for: settings,
                                                 pluginCapabilityExecutor: pluginCapabilityExecutor)
        )
    }

    /// Removes the stored API key for the current provider and disables AI.
    @discardableResult
    public func clearAIKey() -> Bool {
        do {
            try AIKeychain.delete(provider: store.state.assistant.aiSettings.provider)
        } catch {
            logConsole("AI credentials could not be removed",
                       severity: .error,
                       detail: error.localizedDescription)
            return false
        }
        let oldSession = session
        cancelActiveAIRequest()
        let previousTask = pendingAISetupTask
        pendingAISetupTask = Task {
            await previousTask?.value
            await oldSession?.cancelActiveRun()
        }
        session = nil
        store.dispatch(.clearChatHistory)
        agentExecution.assistantMessageID = nil
        var settings = store.state.assistant.aiSettings
        settings.provider = .none
        store.dispatch(.setAISettings(settings))
        return true
    }

    func cancelActiveAIRequest() {
        if agentExecution.proposal != nil, store.pendingConfirmationRequest != nil { skipPendingConfirmation() }
        if agentTaskService.activeTask != nil { updateAgentTask(.cancelled, summary: "Task cancelled") }
        if let id = agentExecution.assistantMessageID {
            store.dispatch(.updateChatMessage(id: id, assistantState: .discarded))
        }
        agentExecution.requestID = nil
        agentExecution.requestTask?.cancel()
        agentExecution.requestTask = nil
        agentExecution.proposal = nil
    }

    /// Returns `true` if a non-empty API key is stored for the current provider.
    public func hasStoredAIKey(for provider: EditorAIProvider? = nil) -> Bool {
        AIKeychain.hasKey(for: provider ?? store.state.assistant.aiSettings.provider)
    }

    public func aiCredentialSource(
        for provider: EditorAIProvider? = nil
    ) -> AICredentialSource? {
        AIKeychain.credentialSource(for: provider ?? store.state.assistant.aiSettings.provider)
    }

    static func workflowContext(
        for mode: EditorWorkspaceMode,
        scriptEntries: [ProjectScriptCatalogEntry] = []
    ) -> WorkflowContext {
        let intent = GameplayIntent(genre: "game", winCondition: "not_specified", pacing: "exploration")
        let constraints = GameKnownConstraints(
            scriptingRegistry: scriptEntries.map(\.identifier),
            scriptSchemas: scriptEntries.map(scriptSchema)
        )
        switch mode {
        case .level, .scripting:
            return .game(GameWorkflowContext(levelPhase: .blockout,
                                            gameplayIntent: intent,
                                            targetExperience: "Interactive level editing",
                                            knownConstraints: constraints))
        case .modeling:
            return .asset(AssetWorkflowContext())
        case .animation:
            return .film(FilmWorkflowContext(activeSequenceID: "animation",
                                              narrativePhase: .blocking, directorIntent: "Animate a 3D film sequence"))
        }
    }

    private static func scriptSchema(_ entry: ProjectScriptCatalogEntry) -> ScriptSchema {
        guard let data = entry.defaultParametersJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScriptSchema(name: entry.identifier)
        }
        let parameters = object.keys.sorted().map { name in
            ScriptParameterDescriptor(name: name,
                                      type: scriptParameterType(object[name]))
        }
        return ScriptSchema(name: entry.identifier, parameters: parameters)
    }

    private static func scriptParameterType(_ value: Any?) -> String {
        switch value {
        case is Bool: return "Bool"
        case is NSNumber: return "Number"
        case is String: return "String"
        case let array as [Any]: return array.count == 3 ? "Vec3" : "Array"
        case is [String: Any]: return "Object"
        default: return "Value"
        }
    }

    static func makeSession(for settings: EditorAISettings,
                            initialWorldView: WorldView = WorldView(),
                            pluginCapabilityExecutor: PluginCapabilityExecutor? = nil,
                            pluginQuerySnapshotProvider: PluginQuerySnapshotProvider? = nil) -> Session? {
        switch settings.provider {
        case .none:
            return nil
        case .anthropic:
            guard let key = AIKeychain.load(provider: .anthropic) else { return nil }
            return Session(config: .anthropic(apiKey: key, model: settings.model, maxTokens: 8192,
                                              autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView,
                           pluginCapabilityExecutor: pluginCapabilityExecutor,
                           pluginQuerySnapshotProvider: pluginQuerySnapshotProvider)
        case .openai:
            guard let key = AIKeychain.load(provider: .openai) else { return nil }
            return Session(config: .openAIResponses(apiKey: key, model: settings.model, maxTokens: 8192,
                                                    autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView,
                           pluginCapabilityExecutor: pluginCapabilityExecutor,
                           pluginQuerySnapshotProvider: pluginQuerySnapshotProvider)
        case .deepseek:
            guard let key = AIKeychain.load(provider: .deepseek) else { return nil }
            return Session(config: .deepSeek(apiKey: key, model: settings.model, maxTokens: 8192,
                                             autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView,
                           pluginCapabilityExecutor: pluginCapabilityExecutor,
                           pluginQuerySnapshotProvider: pluginQuerySnapshotProvider)
        }
    }
}
