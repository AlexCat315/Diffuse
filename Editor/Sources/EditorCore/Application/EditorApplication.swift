import CoveLogging
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
import CoveUICompose
import CoveUIAgent
import CoveUIRuntime
import Foundation
import SIMDCompat

/// 编辑器应用域：把 `EngineHost`、`EditorStore` 与 `InputState` 汇总成一个对象。
///
/// 与 CoveUI 配合使用：
///   1. 启动时由调用方实例化 `EditorApplication`；
///   2. 在 `Application.run` 的 `onTick` 回调里调用 `tick(deltaTime:)` 推进引擎；
///   3. 退出主循环后调用 `shutdown()` 清理引擎资源。
///
/// 自身不持有窗口 / native surface — UI 渲染由 CoveUI 接管，引擎仅负责
/// 仿真与（未来的）离屏渲染。
public final class EditorApplication: @unchecked Sendable {
    public let engine: EngineHost
    public let projectDirectory: String
    /// True when this is the untitled workspace the editor makes because the
    /// user has not opened a project. It backs the workbench and the agent so
    /// both work, but it is not a project: it is never named or listed.
    public var isUntitledWorkspace: Bool { EditorScratchWorkspace.isScratch(projectDirectory) }
    public let store: EditorStore
    public let inputState: InputState
    public let scene: EditorSceneAdapter
    /// Plugin session state: bindings, authorizations and declared components.
    let pluginSession: PluginSession
    /// Manages dynamically compiled Swift scripts in the project.
    public let dynamicScriptManager: DynamicScriptManager
    /// Canonical editor-facing state for script documents, diagnostics, and builds.
    public let workstation: EditorWorkstation
    public private(set) lazy var geometryAuthoring = EditorGeometryAuthoring(app: self)
    public private(set) lazy var meshEditing = EditorMeshEditing(app: self)

    let observationBus: ObservationBus
    let intentCoordinator: IntentRuntimeCoordinator
    /// Host tool policy enforced for the assistant session, the MCP bridge,
    /// and project-tool execution.
    let toolAccess: EditorToolAccess
    let intentTransactionBuilder = IntentTransactionBuilder()
    let aiWorldContext: AIWorldContext
    let perceptionService: PerceptionService
    let events: PlatformEventBridge
    let subscriptions = EditorSubscriptions()
    let diagnosticSession = EditorDiagnosticSession()
    var pendingViewportEvents: [InputEvent] = []
    var _viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)
    private var lastViewportSurfaceState = ViewportSurfaceState()
    var renderGate = EditorViewportRenderGate()
    var renderSettingsGeneration: UInt64 = 0
    var lastQueuedRenderSettings = RenderSettings()
    private var openSettingsWindowHandler: (() -> Void)?
    var closeProjectHandler: (() -> Void)?
    var displayInvalidationHandler: (() -> Void)?
    var activatePanelHandler: ((String) -> Void)?
    private var vsyncModeHandler: ((EditorVSyncMode) -> Void)?
    var session: Session?
    var pendingAISetupTask: Task<Void, Never>?
    var pendingWorldObservationTask: Task<Void, Never>?
    public let agentTaskService = EditorAgentTaskService()
    var agentExecution = EditorAgentExecution()
    var projectToolBuildInProgress = false
    var isShuttingDown = false
    public var isActive: Bool { !isShuttingDown }
    var mcpBridge: AgentLocalServer?
    var pluginCapabilityExecutor: PluginCapabilityExecutor?
    let trustedPluginHostExecutableURL: URL?
    let editLog: EditLog
    let contextMemoryStore: ContextMemoryStore?
    var physicsPlaySnapshot: SceneRuntime?
    var physicsPlayAuthoringRevision: UInt64?
    static let frameStatsDispatchInterval: Double = 1.0
    /// Accumulator for stable FPS averaging.
    var frameTimingAccumulator: Double = 0
    var frameTimingCount: Int = 0
    /// GPU submit time from the most recent rendered frame (seconds).
    var lastRenderSubmitSeconds: Double = 0
    /// Render frame stats from the most recent rendered frame.
    var lastRenderFrameStats: RenderFrameStats = .init()
    /// Scene revision after the last editor-side simulation/extraction pass.
    /// `SceneRuntime.tick` advances its revision even for zero-delta extraction,
    /// so this tracks when authored scene mutations actually need another pass.
    private var lastPreparedSceneRevision: UInt64?
    var launchedPlayerProcess: Process?
    static let editorAutosaveInterval: Double = 10
    var editorAutosaveElapsed: Double = 0
    var lastEditorAutosavedRevision: UInt64?
    var recoverySuppressedRevision: UInt64?
    let projectScriptCatalogMonitor: ProjectScriptCatalogMonitor
    private var projectScriptReloadElapsed: Double = 0
    private static let projectScriptReloadInterval: Double = 1

    public init(projectDirectory: String,
                seedPreviewScene: Bool = false,
                renderDevice: Device? = nil,
                inGameUI: (any InGameUIProviding)? = nil,
                events: PlatformEventBridge = PlatformEventBridge(),
                initialAISettings: EditorAISettings = .default,
                initialCapabilitySettings: EditorCapabilitySettings = .default,
                trustedPluginHostExecutableURL: URL? = nil,
                toolPolicy: ToolPolicy? = nil) throws {
        let toolAccess = EditorToolAccess(policy: toolPolicy ?? EditorToolAudit.policy)
        _ = try EditorAssetCatalog.loadProject(at: projectDirectory)
        ProjectRuntimeResources.configureAudioSearchPaths(at: projectDirectory)
        let store = EditorStore()
        // Resolved on first use: a project with no plugins launches nothing.
        let pluginSession = try PluginSession(projectDirectory: projectDirectory) {
            guard let url = EditorPluginHostLocator.resolve(injectedURL: trustedPluginHostExecutableURL) else {
                throw EditorPluginCapabilityError.pluginHostUnavailable
            }
            return url
        }
        let scene = EditorSceneAdapter(seedPreviewScene: seedPreviewScene,
                                       componentRegistry: pluginSession.components.registry())
        scene.setEditorViewportCameraEnabled(true)
        scene.scriptRuntime.isGameplayExecutionEnabled = false
        let observationDirectory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".cove", isDirectory: true)
            .appendingPathComponent("observation", isDirectory: true)
        try FileManager.default.createDirectory(at: observationDirectory,
                                                withIntermediateDirectories: true)
        let observationBus = try ObservationBus(coldLogDirectory: observationDirectory.path)
        let intentCoordinator = IntentRuntimeCoordinator(
            capabilityPlanner: Self.makeCapabilityInvocationPlanner(for: initialCapabilitySettings)
        )
        // Restore the AI backend from the settings passed in at launch (loaded from
        // EditorShellState by the caller) and the matching stored key.
        store.dispatch(.setAISettings(initialAISettings))
        store.dispatch(.setCapabilitySettings(initialCapabilitySettings))
        let initialSelectedEntityID = scene.defaultSelectionID
        let initialSnapshot = SceneSemanticEncoder().encode(
            scene.scene,
            selectedEntityID: initialSelectedEntityID,
            workspaceMode: store.state.content.rawValue,
            localeIdentifier: nil
        )
        var initialWorldView = WorldView()
        initialWorldView.apply(snapshot: initialSnapshot)
        let initialSession = EditorApplication.makeSession(for: initialAISettings,
                                                           initialWorldView: initialWorldView,
                                                           toolPolicy: toolAccess.policy)

        let ps = PerceptionService()
        let contextMemoryURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".cove", isDirectory: true)
            .appendingPathComponent("context_memory.json")
        let contextMemoryInitialization = Self.initializeContextMemory(at: contextMemoryURL)
        let contextMemoryStore = contextMemoryInitialization.store
        let pluginAuthorizationStore = EditorPluginAuthorizationStore(
            projectDirectory: projectDirectory
        )
        let projectScriptCatalogMonitor = ProjectScriptCatalogMonitor(
            projectDirectory: projectDirectory
        )
        self.engine = EngineHost(runtime: BridgedEngineRuntime(), renderDevice: renderDevice, inGameUI: inGameUI)
        self.projectDirectory = projectDirectory
        self.store = store
        self.inputState = InputState()
        self.scene = scene
        let dynamicScriptManager = DynamicScriptManager(
            projectDirectory: projectDirectory,
            scriptRuntime: scene.scriptRuntime,
            engineModulePaths: Self.resolveEngineModulePaths(),
            clangModuleMapPaths: Self.resolveEngineClangModuleMapPaths(),
            clangIncludePaths: Self.resolveEngineClangIncludePaths()
        )
        self.dynamicScriptManager = dynamicScriptManager
        let scripts = try ScriptWorkspaceModel(
            manager: dynamicScriptManager,
            onScriptLoaded: { file in
                scene.registerDynamicScriptOption(identifier: file.identifier,
                                                  displayName: file.displayName)
                store.dispatch(.forceUIRefresh)
            },
            onScriptDeleted: { file in
                scene.unregisterDynamicScriptOption(identifier: file.identifier)
                store.dispatch(.forceUIRefresh)
            },
            onBuildFailed: { file, message in
                store.dispatch(.appendConsoleMessage("Script compilation failed", severity: .error,
                    detail: message, target: .compilerDiagnostic(scriptID: file.identifier, sourceURL: file.url, output: message),
                    nextStep: "Open the script, fix the reported errors, then Save and Compile."))
            }
        )
        self.workstation = try EditorWorkstation(root: URL(fileURLWithPath: projectDirectory), scripts: scripts,
            plugins: pluginSession.runtime)
        self.observationBus = observationBus
        self.intentCoordinator = intentCoordinator
        self.toolAccess = toolAccess
        self.aiWorldContext = AIWorldContext(worldView: initialWorldView)
        self.events = events
        self.editLog = EditLog(projectDirectory: projectDirectory)
        self.contextMemoryStore = contextMemoryStore
        self.pluginSession = pluginSession
        self.projectScriptCatalogMonitor = projectScriptCatalogMonitor
        self.trustedPluginHostExecutableURL = EditorPluginHostLocator.resolve(
            injectedURL: trustedPluginHostExecutableURL
        )
        self.session = initialSession
        pluginSession.aiProvider = pluginSession.providers.provider(id: initialAISettings.providerID)
        self.perceptionService = ps
        pluginSession.runtime.configure { [weak self] id, event in
            guard let self else { throw PluginManagerError.stopped }
            if self.pluginSession.manager.enabledManifests[id] == nil {
                await self.pluginSession.bundledStartup?.value
            }
            let hosts = self.pluginSession.hosts
            if let binding = self.pluginSession.manager.activeBindings[id],
               let client = hosts.existing(id) { return (binding, client) }
            try await self.activatePlugins(event: event)
            guard let binding = self.pluginSession.manager.activeBindings[id] else { throw PluginManagerError.notEnabled(id) }
            let client = try hosts.client(forPluginID: id)
            return (binding, client)
        }
        dynamicScriptManager.languagePlugin.requestActivation = { [weak self] in
            guard let self else { throw PluginManagerError.stopped }
            // Startup registers bundled declarations before language demand.
            await self.pluginSession.bundledStartup?.value
            try await self.activatePlugins(event: "onLanguage:" + (LanguageCatalog.served?.language.id ?? "swift"))
        }
        if let warning = contextMemoryInitialization.warning {
            logConsole("Recovered AI context memory storage",
                       severity: .warning,
                       detail: warning)
        }
        if let warning = pluginAuthorizationStore.loadWarning {
            logConsole("Recovered plugin authorization storage",
                       severity: .warning,
                       detail: warning)
        }
        #if canImport(Vision)
        Task { await ps.register(AppleVisionPerceptionWorker()) }
        #endif

        scene.onViewportCameraChanged = { [weak self] in
            self?.store.dispatch(.viewportCameraChanged)
            self?.requestDisplayRefresh()
        }
        scene.onRevisionChanged = { [weak self] revision in
            guard let self else { return }
            self.store.dispatch(.setSceneRevision(revision))
            if let suppressed = self.recoverySuppressedRevision,
               suppressed != revision {
                self.recoverySuppressedRevision = nil
            }
        }
        scene.onTransactionError = { [weak self] message in
            guard let self else { return }
            self.logConsole("Scene edit failed", severity: .error, detail: message,
                target: self.store.selectedEntityID.map { .entity(id: $0) },
                nextStep: "Stop playback, check the entity lock and property value, then retry.")
        }
        scene.additionalInspectorSections = { [weak self] id in
            guard let self else { return [] }
            return geometryAuthoring.inspectorSections(for: id)+meshEditing.inspectorSections(for: id)
        }
        store.dispatch(.setSceneRevision(scene.revision))
        store.dispatch(.markSceneSaved(scene.revision))
        if let selection = initialSelectedEntityID {
            store.dispatch(.setSelectedEntity(selection))
        }
        reloadProjectScripts(force: true, reportUnresolvedBindings: false)
        reloadDynamicScripts()

        installCommitPolicies()
        startMCPBridge()

        // Register AIWorldContext as the snapshot provider for the "scene" scope so
        // that the §8 resync protocol is connected end-to-end.
        let worldContextForBus = self.aiWorldContext
        let busForProvider = self.observationBus
        Task { busForProvider.registerSnapshotProvider(worldContextForBus, forScope: "scene") }

        // Propagate initial workflow context, observation bus, and context memory to Session.
        if let initialSession {
            let ctx = Self.workflowContext(for: store.state.content,
                                           scriptEntries: scene.scriptCatalogEntries)
            let bus = observationBus
            let mem = contextMemoryStore
            let projectTools = makeProjectToolExecutor()
            let componentDescriptions = makeComponentDescriptionProvider()
            pendingAISetupTask = Task {
                await initialSession.setProjectToolExecutor(projectTools)
                await initialSession.setComponentDescriptionProvider(componentDescriptions)
                await initialSession.setObservationBus(bus)
                await initialSession.setContextMemory(mem)
                await initialSession.setWorkflowContext(ctx)
            }
        }

        restoreAndObserveViewportSnapSettings()


    }

    public func bootstrap() {
        enableBundledPlugins()
        workstation.tasks.testSource = { [manager = dynamicScriptManager] in try await manager.workspaceTests() }
        workstation.tasks.follow(workstation.scripts)
        subscriptions.events = events.subscribe { [weak self] event in
            self?.handlePlatformEvent(event)
        }
        prepareRendererAtLaunch()
        // 默认启用离屏渲染，让引擎渲染到一个 viewport 纹理交给编辑器显示。
        // 不开启 viewportResolve 时 UI 会一直停在 "Waiting for first render packet"。
        queueTrackedRenderSettings(makeViewportRenderSettings(
            shadowsEnabled: store.state.shadows.enabled,
            shadingMode: store.state.viewport.shadingMode))
    }

    public func tick(deltaTime: Double) {
        for record in subscriptions.console.take() { store.dispatch(.appendLogRecord(record)) }
        // Under the event-driven frame policy the loop can sleep for seconds;
        // the wake-up tick must not step simulation/animation by the whole gap.
        let simulationDelta = min(max(deltaTime, 0), 0.25)
        let didUpdateStats = recordAndDispatchFrameStats(deltaTime: deltaTime,
                                                         simulationDelta: simulationDelta)
        store.dispatch(.tickFrame(store.state.timing.frameIndex &+ 1))
        let inputEvents = pendingViewportEvents
        pendingViewportEvents.removeAll(keepingCapacity: true)
        inputState.process(inputEvents)
        let state = store.state
        let viewportInput = EditorViewportInputController.shared
        let continuousViewportInteractionActive = viewportInput.isContinuousSceneInteractionActive
        let shouldAdvanceSceneSimulation =
            engine.isStarted && ((state.viewport.realtimeEnabled && state.timing.playbackState == .stopped)
                || state.timing.playbackState == .playing)
        if viewportInput.hasFreelookMovementInput {
            driveContinuousViewportCamera(deltaTime: simulationDelta)
        }
        let sceneRevisionBeforePreparation = scene.revision
        let shouldPrepareSceneForRender =
            shouldAdvanceSceneSimulation || sceneRevisionBeforePreparation != lastPreparedSceneRevision
        if shouldPrepareSceneForRender {
            scene.tickScene(deltaTime: shouldAdvanceSceneSimulation ? simulationDelta : 0,
                            frameIndex: state.timing.frameIndex,
                            inputEvents: inputEvents,
                            drivesAudio: state.timing.playbackState == .playing)
            lastPreparedSceneRevision = scene.revision
        }

        let drawableSize = effectiveViewportDrawableSize()
        let jointPalettes = scene.currentJointPaletteMap()
        let geometryOverlays = makeGeometryOverlays(drawableSize: drawableSize)
        let wantsContinuousFrames = EditorViewportFrameDrive.wantsContinuousFrames(
            viewportRealtimeEnabled: state.viewport.realtimeEnabled,
            playbackState: state.timing.playbackState,
            continuousViewportInteractionActive: continuousViewportInteractionActive,
            isPresentationActive: state.shouldRender
        )
        let renderViewport = renderGate.shouldRender(
            signature: EditorViewportRenderGate.Signature(
                sceneRevision: scene.revision,
                camera: scene.currentRenderCamera(),
                drawableSize: drawableSize,
                settingsGeneration: renderSettingsGeneration,
                jointPalettes: jointPalettes,
                geometryOverlays: geometryOverlays
            ),
            forceContinuous: wantsContinuousFrames,
            hasViewportInput: !inputEvents.isEmpty,
            temporalEffectsActive: lastQueuedRenderSettings.postProcessing.taa,
            isPresentationActive: state.shouldRender && engine.isStarted,
            now: monotonicNow()
        )
        let shouldSubmitEngineTick = shouldAdvanceSceneSimulation || renderViewport
        if shouldSubmitEngineTick {
            var renderScene = scene.currentRenderScene()
            renderScene.geometryOverlays = geometryOverlays
            engine.tick(
                deltaTime: shouldAdvanceSceneSimulation ? simulationDelta : 0,
                inputEvents: inputEvents,
                drawableSize: drawableSize,
                shouldRender: state.shouldRender && renderViewport,
                renderSceneOverride: renderScene,
                sceneSnapshotOverride: scene.currentSceneSnapshot(),
                jointPaletteOverride: jointPalettes,
                inGameCanvasOverride: state.viewport.mode == .game && state.viewport.gamePreviewHUDEnabled
                    ? scene.currentInGameCanvas() : InGameCanvas(),
                particleFeedbackHandler: scene.makeParticleSimulationFeedbackHandler(),
                mipmappedViewportOutput: state.viewport.mode == .game && state.viewport.gamePreviewResolution.size != nil
            )
        }

        let surface = engine.currentViewportSurfaceState()
        if surface != lastViewportSurfaceState {
            lastViewportSurfaceState = surface
            store.dispatch(.viewportSurfaceUpdated)
        }
        if didUpdateStats {
            store.dispatch(.updateParticleDiagnostics(makeParticleDiagnosticsSample()))
            store.dispatch(.frameTimingUpdated)
        }
        if wantsContinuousFrames {
            displayInvalidationHandler?()
        }
        projectScriptReloadElapsed += max(0, deltaTime)
        if projectScriptReloadElapsed >= Self.projectScriptReloadInterval {
            projectScriptReloadElapsed = 0
            reloadProjectScripts()
        }
        autosaveSceneIfNeeded(elapsed: deltaTime)
    }

    public func shutdown() {
        subscriptions.console.stop()
        guard !isShuttingDown else { return }
        if meshEditing.isEditing { meshEditing.leave() }
        _ = geometryAuthoring.cancelInteractiveEdit()
        isShuttingDown = true
        cancelRendererPreparation()
        diagnosticSession.close()
        scene.scriptRuntime.isGameplayExecutionEnabled = false
        scene.scriptRuntime.stop(in: &scene.scene)
        workstation.scripts.shutdown()
        workstation.versionControl.stopMonitoring()
        scene.endInteractiveEditHistoryGroup()
        let activeSession = session
        cancelActiveAIRequest()
        if activeSession != nil {
            do {
                try waitForMCPCapabilityResult {
                    await activeSession?.cancelActiveRun()
                }
            } catch {
                logConsole("Failed to cancel the active AI request",
                           severity: .warning,
                           detail: String(describing: error))
            }
        }
        autosaveSceneIfNeeded(elapsed: Self.editorAutosaveInterval, force: true)
        if physicsPlaySnapshot != nil {
            // A clean shutdown must not masquerade as an interrupted Play on
            // the next launch. Crashes never reach this cleanup path.
            deletePersistedPhysicsPlaySnapshot()
        }
        flushContextMemoryBeforeShutdown()
        logConsole("Editor runtime shutdown")
        mcpBridge?.stop()
        mcpBridge = nil
        pluginSession.stop()
        pluginCapabilityExecutor = nil
        if let token = subscriptions.events {
            events.unsubscribe(token)
            subscriptions.events = nil
        }
        if let token = subscriptions.settings {
            store.unsubscribe(token)
            subscriptions.settings = nil
        }
        engine.shutdown()
    }

    public func setOpenSettingsWindowHandler(_ handler: (() -> Void)?) {
        openSettingsWindowHandler = handler
    }

    public func openSettingsWindow() {
        openSettingsWindowHandler?()
    }

    /// Whether the configured provider currently has a usable runtime session.
    /// A provider name can be restored from shell state while its stored
    /// credential is missing, so UI should not treat `provider != .none` as
    /// sufficient proof that requests can be submitted.
    public var isAIAvailable: Bool {
        isAgentEnabled && session != nil
    }

    /// Drops or restores the assistant session when the agent package that owns
    /// it is enabled or disabled. Disabling must leave no runtime behind, not
    /// merely hide the panel.
    @MainActor
    func rebuildAgentSurfaces() {
        guard !isShuttingDown else { return }
        if isAgentEnabled {
            let settings = store.state.assistant.aiSettings
            guard session == nil, settings.isEnabled else { return }
            session = Self.makeSession(
                for: settings,
                providers: aiProviderCatalog,
                agent: agentCatalog.agent(id: settings.agentID),
                pluginCapabilityExecutor: pluginCapabilityExecutor,
                pluginQuerySnapshotProvider: makePluginQuerySnapshotProvider(),
                toolPolicy: toolAccess.policy
            )
            pluginSession.aiProvider = aiProviderCatalog.provider(id: settings.providerID)
        } else {
            let oldSession = session
            cancelActiveAIRequest()
            session = nil
            pluginSession.aiProvider = nil
            agentExecution.assistantMessageID = nil
            let previousTask = pendingAISetupTask
            pendingAISetupTask = Task {
                await previousTask?.value
                await oldSession?.cancelActiveRun()
            }
            store.dispatch(.clearChatHistory)
        }
        displayInvalidationHandler?()
    }

    public var isSceneAuthoringEnabled: Bool {
        store.state.timing.playbackState == .stopped && scene.isAuthoringEnabled
    }

    public func setDisplayInvalidationHandler(_ handler: (@Sendable () -> Void)?) {
        subscriptions.console.setWake(handler)
        displayInvalidationHandler = handler
    }

    public func requestDisplayRefresh() {
        displayInvalidationHandler?()
    }

    public func logConsole(_ message: String,
                           severity: EditorConsoleSeverity = .info,
                           detail: String? = nil, target: EditorIssueTarget? = nil,
                           nextStep: String? = nil) {
        LogContext.withValues(["project": "\(projectDirectory)"]) {
            store.dispatch(.appendConsoleMessage(message, severity: severity, detail: detail, target: target, nextStep: nextStep))
        }
    }

    public func setVSyncModeHandler(_ handler: ((EditorVSyncMode) -> Void)?) {
        vsyncModeHandler = handler
    }

    public func applyVSyncMode(_ mode: EditorVSyncMode) {
        vsyncModeHandler?(mode)
    }
}
