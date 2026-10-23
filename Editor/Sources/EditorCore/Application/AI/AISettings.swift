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
import NativeRHI
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    // MARK: - AI settings

    /// Applies new AI settings: persists provider/model, writes the key to the credential file,
    /// and hot-swaps the Session without restart.
    @discardableResult
    public func applyAISettings(_ settings: EditorAISettings, apiKey: String) -> Bool {
        let provider = aiProviderCatalog.provider(id: settings.providerID)
        do {
            if settings.isEnabled, !apiKey.isEmpty {
                try AICredentialStore.save(key: apiKey, providerID: settings.providerID)
            }
            // Read the secret once here, on the user's Apply, so a key the
            // session cannot use fails now instead of leaving AI silently off.
            if settings.isEnabled {
                guard let provider,
                      AICredentialStore.load(providerID: settings.providerID,
                                             environmentVariable: provider.environmentVariable) != nil else {
                    logConsole("AI settings were not applied",
                               severity: .error,
                               detail: "Enter an API key for \(provider?.title ?? settings.providerID).")
                    return false
                }
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
            providers: aiProviderCatalog,
            pluginCapabilityExecutor: pluginCapabilityExecutor,
            pluginQuerySnapshotProvider: makePluginQuerySnapshotProvider(),
            toolPolicy: toolAccess.policy
        )
        if oldSession != nil || newSession != nil {
            let worldContext = self.aiWorldContext
            let ctx = Self.workflowContext(for: store.state.workspace.mode,
                                           scriptEntries: scene.scriptCatalogEntries)
            let bus = self.observationBus
            let mem = self.contextMemoryStore
            let previousTask = pendingAISetupTask
            let projectTools = makeProjectToolExecutor()
            let componentDescriptions = makeComponentDescriptionProvider()
            pendingAISetupTask = Task {
                await previousTask?.value
                await oldSession?.cancelActiveRun()
                if let newSession {
                    await newSession.setProjectToolExecutor(projectTools)
                    await newSession.setComponentDescriptionProvider(componentDescriptions)
                    await newSession.replaceWorldView(await worldContext.snapshot())
                    await newSession.setObservationBus(bus)
                    await newSession.setContextMemory(mem)
                    await newSession.setWorkflowContext(ctx)
                }
            }
        }
        session = newSession
        pluginSession.aiProvider = provider
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
            try AICredentialStore.delete(providerID: store.state.assistant.aiSettings.providerID)
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
        settings.providerID = ""
        settings.model = ""
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

    /// Returns `true` if a non-empty API key is stored for the provider.
    public func hasStoredAIKey(for providerID: String? = nil) -> Bool {
        let id = providerID ?? store.state.assistant.aiSettings.providerID
        guard let provider = aiProviderCatalog.provider(id: id) else { return false }
        return AICredentialStore.hasKey(for: id, environmentVariable: provider.environmentVariable)
    }

    public func aiCredentialSource(for providerID: String? = nil) -> AICredentialSource? {
        let id = providerID ?? store.state.assistant.aiSettings.providerID
        guard let provider = aiProviderCatalog.provider(id: id) else { return nil }
        return AICredentialStore.credentialSource(for: id,
                                                  environmentVariable: provider.environmentVariable)
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
        case .documents: return .workstation(WorkstationContext(domain: .documents))
        case .video: return .workstation(WorkstationContext(domain: .media))
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
                            providers: AIProviderCatalog = .bundled,
                            initialWorldView: WorldView = WorldView(),
                            pluginCapabilityExecutor: PluginCapabilityExecutor? = nil,
                            pluginQuerySnapshotProvider: PluginQuerySnapshotProvider? = nil,
                            toolPolicy: ToolPolicy? = nil) -> Session? {
        guard settings.isEnabled,
              let provider = providers.provider(id: settings.providerID),
              let apiFormat = apiFormat(for: provider),
              let baseURL = provider.baseURL.flatMap(URL.init(string:)),
              let key = AICredentialStore.load(providerID: provider.id,
                                               environmentVariable: provider.environmentVariable) else {
            return nil
        }
        let model = provider.models.first { $0.id == settings.model }
            ?? provider.models.first { $0.id == provider.defaultModel }
        guard let model else { return nil }
        let config = SessionConfig(apiKey: key,
                                   model: model.id,
                                   maxTokens: model.maxOutputTokens ?? 8192,
                                   baseURL: baseURL,
                                   apiFormat: apiFormat,
                                   autoApprove: settings.autoApprove)
        return Session(config: config,
                       initialWorldView: initialWorldView,
                       pluginCapabilityExecutor: pluginCapabilityExecutor,
                       pluginQuerySnapshotProvider: pluginQuerySnapshotProvider,
                       toolPolicy: toolPolicy)
    }

    private static func apiFormat(for provider: AIProviderDescriptor) -> SessionAPIFormat? {
        switch provider.apiFormat {
        case "anthropic": .anthropic
        case "openai-responses": .openAIResponses
        case "openai-compatible": .openAICompatible
        default: nil
        }
    }
}
