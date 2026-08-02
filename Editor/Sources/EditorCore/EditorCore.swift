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

private enum MCPAsyncBridgeError: Error, CustomStringConvertible {
    case timedOut
    case missingResult

    var description: String {
        switch self {
        case .timedOut: return "asynchronous editor operation timed out"
        case .missingResult: return "asynchronous editor operation returned no result"
        }
    }
}

public enum EditorPluginCapabilityError: Error, Sendable, Equatable, LocalizedError {
    case pluginHostUnavailable
    case pluginAlreadyEnabled(String)
    case pluginNotEnabled(String)
    case noPendingPluginApproval
    case missingExposureSnapshot
    case sceneRevisionChanged(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .pluginHostUnavailable:
            return "The trusted GuavaPluginHost executable is unavailable. Rebuild or reinstall the Editor."
        case let .pluginAlreadyEnabled(id):
            return "Plugin '\(id)' is already enabled. Disable it before loading another version."
        case let .pluginNotEnabled(id):
            return "Plugin '\(id)' is not enabled."
        case .noPendingPluginApproval:
            return "No inspected plugin is waiting for approval."
        case .missingExposureSnapshot:
            return "The plugin plan is missing its capability exposure snapshot."
        case let .sceneRevisionChanged(expected, actual):
            return "The scene changed while preparing plugin data (expected \(expected), actual \(actual))."
        }
    }
}

private final class MCPAsyncResultBox<Value: Sendable>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

/// The editor bridge is intentionally synchronous on its local TCP boundary.
/// Capability authority lives in an actor, so only the small actor operation is
/// awaited here; scene reads and transaction preparation remain on the editor
/// queue after this function returns.
private func waitForMCPCapabilityResult<Value: Sendable>(
    timeout: TimeInterval = 5,
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = MCPAsyncResultBox<Value>()
    Task {
        do {
            box.result = .success(try await operation())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw MCPAsyncBridgeError.timedOut
    }
    guard let result = box.result else { throw MCPAsyncBridgeError.missingResult }
    return try result.get()
}

/// 编辑器应用域：把 `EngineHost`、`EditorStore` 与 `InputState` 汇总成一个对象。
///
/// 与 GuavaUIApp 配合使用：
///   1. 启动时由调用方实例化 `EditorApplication`；
///   2. 在 `AppRuntime.run` 的 `onTick` 回调里调用 `tick(deltaTime:)` 推进引擎；
///   3. 退出主循环后调用 `shutdown()` 清理引擎资源。
///
/// 自身不持有窗口 / wgpu surface — UI 渲染由 GuavaUIApp 接管，引擎仅负责
/// 仿真与（未来的）离屏渲染。
public final class EditorApplication: @unchecked Sendable {
    private struct ContextMemoryInitialization {
        var store: ContextMemoryStore?
        var warning: String?
    }

    private var exportedApplicationName: String {
        let name = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Guava Game" : name
    }
    private struct PendingPluginApproval {
        var packageURL: URL
        var inspection: PluginInspection
    }

    public let engine: EngineHost
    public let projectDirectory: String
    public let store: EditorStore
    public let inputState: InputState
    public let scene: EditorSceneAdapter

    private let observationBus: ObservationBus
    private let intentCoordinator: IntentRuntimeCoordinator
    private let intentTransactionBuilder = IntentTransactionBuilder()
    private let aiWorldContext: AIWorldContext
    private let perceptionService: PerceptionService
    private let events: PlatformEventBridge
    private var eventToken: PlatformEventBridge.SubscriptionToken?
    private var workspaceModeToken: EditorStore.SubscriptionToken?
    private var pendingViewportEvents: [InputEvent] = []
    private var _viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)
    private var lastViewportSurfaceState = ViewportSurfaceState()
    private var renderGate = EditorViewportRenderGate()
    private var renderSettingsGeneration: UInt64 = 0
    private var lastQueuedRenderSettings = RenderSettings()
    private var openSettingsWindowHandler: (() -> Void)?
    private var displayInvalidationHandler: (() -> Void)?
    private var vsyncModeHandler: ((EditorVSyncMode) -> Void)?
    private var session: Session?
    private var pendingAISetupTask: Task<Void, Never>?
    private var pendingWorldObservationTask: Task<Void, Never>?
    private var activeAIRequestID: UUID?
    private var activeAIRequestTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var pendingSessionProposal: Proposal?
    private var pendingAssistantMessageID: String?
    /// Existing scene entities referenced by the plan currently awaiting approval.
    /// This lets a lock added after preview still prevent the confirmed mutation.
    private var pendingConfirmationTargetEntityIDs: Set<UInt64> = []
    private let mcpBridge = MCPBridge()
    private let mcpCapabilitySessions = CapabilityExposureSessionStore()
    private var pluginHostClient: PluginHostProcessClient?
    private var pluginBindings: [String: PluginExecutionBinding] = [:]
    private var pluginCapabilityExecutor: PluginCapabilityExecutor?
    private let pluginAuthorizationStore: EditorPluginAuthorizationStore
    private let trustedPluginHostExecutableURL: URL?
    private var pendingPluginApproval: PendingPluginApproval?
    private let editLog: EditLog
    private let contextMemoryStore: ContextMemoryStore?
    private var physicsPlaySnapshot: SceneRuntime?
    private static let frameStatsDispatchInterval: Double = 1.0
    /// Accumulator for stable FPS averaging.
    private var frameTimingAccumulator: Double = 0
    private var frameTimingCount: Int = 0
    /// GPU submit time from the most recent rendered frame (seconds).
    private var lastRenderSubmitSeconds: Double = 0
    /// Render frame stats from the most recent rendered frame.
    private var lastRenderFrameStats: RenderFrameStats = .init()
    /// Scene revision after the last editor-side simulation/extraction pass.
    /// `SceneRuntime.tick` advances its revision even for zero-delta extraction,
    /// so this tracks when authored scene mutations actually need another pass.
    private var lastPreparedSceneRevision: UInt64?
    private var launchedPlayerProcess: Process?
    private static let editorAutosaveInterval: Double = 10
    private var editorAutosaveElapsed: Double = 0
    private var lastEditorAutosavedRevision: UInt64?
    private var recoverySuppressedRevision: UInt64?
    private let projectScriptCatalogMonitor: ProjectScriptCatalogMonitor
    private var projectScriptReloadElapsed: Double = 0
    private static let projectScriptReloadInterval: Double = 1

    /// Revision equality covers ordinary edits/undo. A recovered autosave is
    /// explicitly dirty because rebuilding two structurally similar manifests
    /// can legitimately produce the same runtime revision.
    public var hasUnsavedSceneChanges: Bool {
        store.state.sceneDirty
    }

    public init(projectDirectory: String,
                backendConfig: WGPUDeviceConfig? = nil,
                backend: WGPUBackend? = nil,
                events: PlatformEventBridge = PlatformEventBridge(),
                initialAISettings: EditorAISettings = .default,
                initialCapabilitySettings: EditorCapabilitySettings = .default,
                trustedPluginHostExecutableURL: URL? = nil) throws {
        let resolvedBackendConfig = backendConfig ?? .init()
        let resolvedBackend = backend ?? WGPUBackend(config: resolvedBackendConfig)
        _ = try EditorAssetCatalog.loadProject(at: projectDirectory)
        ProjectRuntimeResources.configureAudioSearchPaths(at: projectDirectory)
        let store = EditorStore()
        let scene = EditorSceneAdapter()
        let observationDirectory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("observation", isDirectory: true)
        try FileManager.default.createDirectory(at: observationDirectory,
                                                withIntermediateDirectories: true)
        let observationBus = try ObservationBus(coldLogDirectory: observationDirectory.path)
        let intentCoordinator = IntentRuntimeCoordinator(
            capabilityPlanner: Self.makeCapabilityInvocationPlanner(for: initialCapabilitySettings)
        )
        // Restore the AI backend from the settings passed in at launch (loaded from
        // EditorShellState by the caller) and the matching key in Keychain.
        store.dispatch(.setAISettings(initialAISettings))
        store.dispatch(.setCapabilitySettings(initialCapabilitySettings))
        let initialSelectedEntityID = scene.defaultSelectionID
        let initialSnapshot = SceneSemanticEncoder().encode(
            scene.scene,
            selectedEntityID: initialSelectedEntityID,
            workspaceMode: store.state.workspaceMode.rawValue,
            localeIdentifier: nil
        )
        var initialWorldView = WorldView()
        initialWorldView.apply(snapshot: initialSnapshot)
        let initialSession = EditorApplication.makeSession(for: initialAISettings,
                                                           initialWorldView: initialWorldView)

        let ps = PerceptionService()
        let contextMemoryURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("context_memory.json")
        let contextMemoryInitialization = Self.initializeContextMemory(at: contextMemoryURL)
        let contextMemoryStore = contextMemoryInitialization.store
        let pluginAuthorizationStore = EditorPluginAuthorizationStore(
            projectDirectory: projectDirectory
        )
        let projectScriptCatalogMonitor = ProjectScriptCatalogMonitor(
            projectDirectory: projectDirectory
        )
        self.engine = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: resolvedBackend)
        self.projectDirectory = projectDirectory
        self.store = store
        self.inputState = InputState()
        self.scene = scene
        self.observationBus = observationBus
        self.intentCoordinator = intentCoordinator
        self.aiWorldContext = AIWorldContext(worldView: initialWorldView)
        self.events = events
        self.editLog = EditLog(projectDirectory: projectDirectory)
        self.contextMemoryStore = contextMemoryStore
        self.pluginAuthorizationStore = pluginAuthorizationStore
        self.projectScriptCatalogMonitor = projectScriptCatalogMonitor
        self.trustedPluginHostExecutableURL = EditorPluginHostLocator.resolve(
            injectedURL: trustedPluginHostExecutableURL
        )
        self.session = initialSession
        self.perceptionService = ps
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

        scene.onRevisionChanged = { [weak self] revision in
            guard let self else { return }
            self.store.dispatch(.setSceneRevision(revision))
            if let suppressed = self.recoverySuppressedRevision,
               suppressed != revision {
                self.recoverySuppressedRevision = nil
            }
        }
        scene.onTransactionError = { [weak self] message in
            self?.logConsole("Scene edit failed", severity: .error, detail: message)
        }
        store.dispatch(.setSceneRevision(scene.revision))
        store.dispatch(.markSceneSaved(scene.revision))
        if let selection = initialSelectedEntityID {
            store.dispatch(.setSelectedEntity(selection))
        }
        reloadProjectScripts(force: true)

        startMCPBridge()

        // Register AIWorldContext as the snapshot provider for the "scene" scope so
        // that the §8 resync protocol is connected end-to-end.
        let worldContextForBus = self.aiWorldContext
        let busForProvider = self.observationBus
        Task { busForProvider.registerSnapshotProvider(worldContextForBus, forScope: "scene") }

        // Propagate initial workflow context, observation bus, and context memory to Session.
        if let initialSession {
            let ctx = Self.workflowContext(for: store.state.workspaceMode,
                                           scriptEntries: scene.scriptCatalogEntries)
            let bus = observationBus
            let mem = contextMemoryStore
            pendingAISetupTask = Task {
                await initialSession.setObservationBus(bus)
                await initialSession.setContextMemory(mem)
                await initialSession.setWorkflowContext(ctx)
            }
        }

        // Keep Session's WorkflowContext in sync when the user switches workspace mode.
        var lastObservedMode: EditorWorkspaceMode = store.state.workspaceMode
        workspaceModeToken = store.subscribe { [weak self] s in
            guard let self else { return }
            let newMode = s.state.workspaceMode
            guard newMode != lastObservedMode, let sess = self.session else { return }
            lastObservedMode = newMode
            let ctx = Self.workflowContext(for: newMode,
                                           scriptEntries: self.scene.scriptCatalogEntries)
            let previousTask = self.pendingAISetupTask
            self.pendingAISetupTask = Task {
                await previousTask?.value
                await sess.setWorkflowContext(ctx)
            }
        }
    }

    private static func initializeContextMemory(at storageURL: URL) -> ContextMemoryInitialization {
        do {
            return ContextMemoryInitialization(
                store: try ContextMemoryStore(storageURL: storageURL),
                warning: nil
            )
        } catch {
            let originalError = error
            guard FileManager.default.fileExists(atPath: storageURL.path) else {
                return ContextMemoryInitialization(
                    store: nil,
                    warning: "Context memory could not be initialized: \(originalError)"
                )
            }
            let quarantineURL = storageURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: storageURL, to: quarantineURL)
                let replacement = try ContextMemoryStore(storageURL: storageURL)
                return ContextMemoryInitialization(
                    store: replacement,
                    warning: "The unreadable file was moved to \(quarantineURL.lastPathComponent): \(originalError)"
                )
            } catch {
                return ContextMemoryInitialization(
                    store: nil,
                    warning: "Context memory is disabled because recovery failed: \(error); original error: \(originalError)"
                )
            }
        }
    }

    public func bootstrap() {
        eventToken = events.subscribe { [weak self] event in
            self?.handlePlatformEvent(event)
        }
        engine.start(renderSurface: nil, enableViewportSurface: true)
        // 默认启用离屏渲染，让引擎渲染到一个 viewport 纹理交给编辑器显示。
        // 不开启 viewportResolve 时 UI 会一直停在 "Waiting for first render packet"。
        queueTrackedRenderSettings(makeViewportRenderSettings(
            shadowsEnabled: store.state.viewportShadowsEnabled,
            shadingMode: store.state.viewportShadingMode))
        store.dispatch(.setConnected(true))
        logConsole("Editor connected to runtime")
    }

    public func tick(deltaTime: Double) {
        // Under the event-driven frame policy the loop can sleep for seconds;
        // the wake-up tick must not step simulation/animation by the whole gap.
        let simulationDelta = min(max(deltaTime, 0), 0.25)
        let didUpdateStats = recordAndDispatchFrameStats(deltaTime: deltaTime,
                                                         simulationDelta: simulationDelta)
        store.dispatch(.tickFrame(store.state.frameIndex &+ 1))
        let inputEvents = pendingViewportEvents
        pendingViewportEvents.removeAll(keepingCapacity: true)
        inputState.process(inputEvents)
        let state = store.state
        let viewportInput = EditorViewportInputController.shared
        let continuousViewportInteractionActive = viewportInput.isContinuousSceneInteractionActive
        let shouldAdvanceSceneSimulation =
            state.viewportRealtimeEnabled || state.playbackState == .playing
        if viewportInput.hasFreelookMovementInput {
            driveContinuousViewportCamera(deltaTime: simulationDelta)
        }
        let sceneRevisionBeforePreparation = scene.revision
        let shouldPrepareSceneForRender =
            shouldAdvanceSceneSimulation || sceneRevisionBeforePreparation != lastPreparedSceneRevision
        if shouldPrepareSceneForRender {
            scene.tickScene(deltaTime: shouldAdvanceSceneSimulation ? simulationDelta : 0,
                            frameIndex: state.frameIndex,
                            inputEvents: inputEvents,
                            drivesAudio: state.playbackState == .playing)
            lastPreparedSceneRevision = scene.revision
        }

        let drawableSize = effectiveViewportDrawableSize()
        let jointPalettes = scene.currentJointPaletteMap()
        let wantsContinuousFrames = EditorViewportFrameDrive.wantsContinuousFrames(
            viewportRealtimeEnabled: state.viewportRealtimeEnabled,
            playbackState: state.playbackState,
            sceneHasActiveParticles: state.viewportRealtimeEnabled && scene.hasActiveParticles(),
            continuousViewportInteractionActive: continuousViewportInteractionActive
        )
        let renderViewport = renderGate.shouldRender(
            signature: EditorViewportRenderGate.Signature(
                sceneRevision: scene.revision,
                camera: scene.currentRenderCamera(),
                drawableSize: drawableSize,
                settingsGeneration: renderSettingsGeneration,
                jointPalettes: jointPalettes
            ),
            forceContinuous: wantsContinuousFrames,
            hasViewportInput: !inputEvents.isEmpty,
            temporalEffectsActive: lastQueuedRenderSettings.enableTAA,
            now: monotonicNow()
        )
        let shouldSubmitEngineTick = shouldAdvanceSceneSimulation || renderViewport
        if shouldSubmitEngineTick {
            engine.tick(
                deltaTime: shouldAdvanceSceneSimulation ? simulationDelta : 0,
                inputEvents: inputEvents,
                drawableSize: drawableSize,
                shouldRender: state.shouldRender && renderViewport,
                renderSceneOverride: scene.currentRenderScene(),
                sceneSnapshotOverride: scene.currentSceneSnapshot(),
                jointPaletteOverride: jointPalettes,
                inGameCanvasOverride: scene.currentInGameCanvas(),
                particleFeedbackHandler: scene.makeParticleSimulationFeedbackHandler()
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
        isShuttingDown = true
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
        mcpBridge.stop()
        pluginHostClient?.stop()
        pluginHostClient = nil
        pluginBindings.removeAll()
        pluginCapabilityExecutor = nil
        pendingPluginApproval = nil
        if let eventToken {
            events.unsubscribe(eventToken)
            self.eventToken = nil
        }
        if let workspaceModeToken {
            store.unsubscribe(workspaceModeToken)
            self.workspaceModeToken = nil
        }
        engine.shutdown()
    }

    private func flushContextMemoryBeforeShutdown() {
        guard let contextMemoryStore else { return }
        let setupTask = pendingAISetupTask
        let observationTask = pendingWorldObservationTask
        do {
            try waitForMCPCapabilityResult {
                await setupTask?.value
                await observationTask?.value
                try await contextMemoryStore.flush()
            }
            pendingAISetupTask = nil
            pendingWorldObservationTask = nil
        } catch {
            logConsole("Failed to persist AI context memory",
                       severity: .error,
                       detail: String(describing: error))
        }
    }

    public func enqueueViewportInput(_ event: InputEvent) {
        pendingViewportEvents.append(event)
        displayInvalidationHandler?()
    }

    /// Presentation size of the viewport in physical pixels (reported by
    /// `ViewportHost`). The engine renders this scaled by the render-scale
    /// settings — see `effectiveViewportDrawableSize()`.
    public var viewportDrawableSize: RenderDrawableSize { _viewportDrawableSize }

    private func driveContinuousViewportCamera(deltaTime: Double) {
        let viewportInput = EditorViewportInputController.shared
        guard viewportInput.hasFreelookMovementInput else { return }
        scene.freelookCamera(deltaScreenX: 0,
                             deltaScreenY: 0,
                             pressedScancodes: viewportInput.pressedScancodes,
                             modifiers: viewportInput.modifiers,
                             deltaTime: Float(max(0, deltaTime)))
    }

    public func setViewportDrawableSize(_ size: RenderDrawableSize) {
        guard _viewportDrawableSize != size else { return }
        _viewportDrawableSize = size
    }

    private func effectiveViewportDrawableSize() -> RenderDrawableSize {
        let state = store.state
        let interacting = state.viewportInteractionDownscaleEnabled
            && EditorViewportInputController.shared.isContinuousSceneInteractionActive
        return EditorViewportResolution.effectiveSize(
            presentation: _viewportDrawableSize,
            renderScalePercent: state.viewportRenderScalePercent,
            interactionDownscaleActive: interacting
        )
    }

    public func setViewportRenderScalePercent(_ percent: Int) {
        let sanitized = EditorState.sanitizedRenderScalePercent(percent)
        guard store.state.viewportRenderScalePercent != sanitized else { return }
        store.dispatch(.setViewportRenderScalePercent(sanitized))
        logConsole("Viewport render scale \(sanitized)%")
    }

    public func setViewportInteractionDownscaleEnabled(_ enabled: Bool) {
        guard store.state.viewportInteractionDownscaleEnabled != enabled else { return }
        store.dispatch(.setViewportInteractionDownscale(enabled))
        logConsole(enabled ? "Viewport interaction downscale enabled"
                           : "Viewport interaction downscale disabled")
    }

    public func setViewportRealtimeEnabled(_ enabled: Bool) {
        guard store.state.viewportRealtimeEnabled != enabled else { return }
        store.dispatch(.setViewportRealtime(enabled))
        logConsole(enabled ? "Viewport realtime rendering enabled"
                           : "Viewport renders on demand")
        displayInvalidationHandler?()
    }

    private func monotonicNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public func setViewportRenderCompletionHandler(_ handler: (@Sendable (ViewportSurfaceState) -> Void)?) {
        engine.setRenderCompletionHandler { [weak self] completion in
            guard let self else { return }
            self.lastRenderSubmitSeconds = completion.renderSubmitSeconds
            self.lastRenderFrameStats = completion.stats
            handler?(completion.viewportSurfaceState)
        }
    }

    public func setOpenSettingsWindowHandler(_ handler: (() -> Void)?) {
        openSettingsWindowHandler = handler
    }

    public func openSettingsWindow() {
        openSettingsWindowHandler?()
    }

    /// Whether the configured provider currently has a usable runtime session.
    /// A provider name can be restored from shell state while its Keychain
    /// credential is missing, so UI should not treat `provider != .none` as
    /// sufficient proof that requests can be submitted.
    public var isAIAvailable: Bool {
        session != nil
    }

    public var isSceneAuthoringEnabled: Bool {
        store.state.playbackState == .stopped && scene.isAuthoringEnabled
    }

    public func setDisplayInvalidationHandler(_ handler: (() -> Void)?) {
        displayInvalidationHandler = handler
    }

    public func requestDisplayRefresh() {
        displayInvalidationHandler?()
    }

    public func logConsole(_ message: String,
                           severity: EditorConsoleSeverity = .info,
                           detail: String? = nil) {
        store.dispatch(.appendConsoleMessage(message, severity: severity, detail: detail))
    }

    public func setVSyncModeHandler(_ handler: ((EditorVSyncMode) -> Void)?) {
        vsyncModeHandler = handler
    }

    public func applyVSyncMode(_ mode: EditorVSyncMode) {
        vsyncModeHandler?(mode)
    }

    /// 把资产生成到场景中，并把新实体设为当前选中。
    @discardableResult
    public func spawnAsset(_ asset: EditorAsset, at position: SIMD3<Float> = .zero) -> UInt64? {
        guard asset.kind.isMesh else {
            logConsole("Cannot spawn \(asset.name)", severity: .warning, detail: asset.kind.sceneKindLabel)
            return nil
        }
        guard let id = scene.spawnEntity(from: asset, at: position) else {
            logConsole("Failed to spawn \(asset.name)", severity: .error)
            return nil
        }
        store.dispatch(.setSelectedEntity(id))
        logConsole("Spawned \(asset.name)", detail: "entity \(id)")
        runSemanticAnnotation(entityID: id, asset: asset)
        return id
    }

    private func runSemanticAnnotation(entityID: UInt64, asset: EditorAsset) {
        guard let mesh = AssetRegistry.shared.meshAsset(for: asset.meshIndex) else { return }
        let entityRef = "scene:\(entityID)"
        let assetURI = asset.relativePath

        let previewImagePath = Self.siblingPreviewImagePath(for: asset.absolutePath)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let raw = Self.buildRawStructure(from: mesh, assetURI: assetURI,
                                             previewImagePath: previewImagePath)
            let signals = Self.buildGeometrySignals(from: mesh, assetURI: assetURI)
            let pipeline = AssetSemanticPipeline.standard()
            let decision = await pipeline.run(rawStructure: raw, signals: signals)

            let proposals: [SemanticProposal]
            switch decision {
            case let .autoCommit(committed): proposals = committed
            case .needsConfirmation: return
            }

            guard !proposals.isEmpty else { return }
            let events = SemanticWorldEventMapper().makeWorldEvents(from: proposals, targetRef: entityRef)
            guard !events.isEmpty else { return }

            await MainActor.run {
                guard !self.isShuttingDown else { return }
                self.observeWorldEvents(events)
                self.logConsole("Semantic annotations applied to \(entityRef)",
                                detail: "\(proposals.count) proposals")
            }
        }
    }

    private static func siblingPreviewImagePath(for absolutePath: String) -> String? {
        let base = (absolutePath as NSString).deletingPathExtension
        for ext in ["png", "jpg", "jpeg", "PNG", "JPG", "JPEG"] {
            let candidate = "\(base).\(ext)"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func buildRawStructure(from mesh: MeshAsset,
                                          assetURI: String,
                                          previewImagePath: String? = nil) -> RawStructure {
        var nodes: [RawStructure.Node] = []
        for (i, node) in mesh.nodes.enumerated() {
            let t = node.localTranslation
            let s = node.localScale
            // Column-major 4×4 from TRS (simplified; rotation from quaternion)
            let transform: [Float] = [
                s.x, 0, 0, 0,
                0, s.y, 0, 0,
                0, 0, s.z, 0,
                t.x, t.y, t.z, 1,
            ]
            nodes.append(RawStructure.Node(id: "node_\(i)",
                                           name: node.name ?? "node_\(i)",
                                           parentID: node.parentIndex.map { "node_\($0)" },
                                           localTransform: transform))
        }

        let meshRecord = RawStructure.MeshRecord(id: "mesh_0",
                                                 nodeID: nodes.first?.id ?? "node_0",
                                                 vertexCount: mesh.vertexCount,
                                                 faceCount: mesh.triangleCount)

        var submeshRecords: [RawStructure.SubmeshRecord] = []
        for (i, sub) in mesh.submeshes.enumerated() {
            submeshRecords.append(RawStructure.SubmeshRecord(id: "sub_\(i)",
                                                             meshID: "mesh_0",
                                                             materialSlot: sub.materialIndex,
                                                             indexStart: Int(sub.indexStart),
                                                             indexCount: Int(sub.indexCount)))
        }

        var materialSlots: [RawStructure.MaterialSlot] = []
        for (i, mat) in mesh.materials.enumerated() {
            materialSlots.append(RawStructure.MaterialSlot(id: "mat_\(i)",
                                                           name: mat.name ?? "material_\(i)",
                                                           sourceIndex: i))
        }

        var bones: [RawStructure.Bone] = []
        for skin in mesh.skins {
            for jointIndex in skin.jointNodeIndices {
                guard jointIndex < mesh.nodes.count else { continue }
                let node = mesh.nodes[jointIndex]
                let boneID = "bone_\(jointIndex)"
                let parentBoneID: String? = {
                    guard let parentIdx = node.parentIndex,
                          skin.jointNodeIndices.contains(parentIdx) else { return nil }
                    return "bone_\(parentIdx)"
                }()
                bones.append(RawStructure.Bone(id: boneID,
                                               name: node.name ?? boneID,
                                               parentID: parentBoneID))
            }
        }
        let skeleton: RawStructure.Skeleton? = bones.isEmpty ? nil : RawStructure.Skeleton(bones: bones)

        return RawStructure(assetURI: assetURI,
                            previewImagePath: previewImagePath,
                            nodes: nodes,
                            meshes: [meshRecord],
                            submeshes: submeshRecords,
                            materialSlots: materialSlots,
                            skeleton: skeleton)
    }

    private static func buildGeometrySignals(from mesh: MeshAsset, assetURI: String) -> GeometrySignals {
        let bounds = mesh.localBounds
        let aabb = GeometrySignals.AABB(
            min: (bounds.min.x, bounds.min.y, bounds.min.z),
            max: (bounds.max.x, bounds.max.y, bounds.max.z)
        )
        let component = GeometrySignals.ConnectedComponent(
            id: "cc_0",
            meshID: "mesh_0",
            faceCount: mesh.triangleCount,
            bounds: aabb
        )
        let dx = bounds.max.x - bounds.min.x
        let dy = bounds.max.y - bounds.min.y
        let dz = bounds.max.z - bounds.min.z
        let surfaceArea = 2 * (dx * dy + dy * dz + dx * dz)
        let volumeEstimate = dx * dy * dz
        return GeometrySignals(assetURI: assetURI,
                               connectedComponents: [component],
                               surfaceArea: surfaceArea,
                               volumeEstimate: volumeEstimate)
    }

    /// Runs visual perception on `imageURL` and injects the resulting inferred properties
    /// into the World and the active Session for the given entity.
    /// Call this from the UI or MCP after the user selects a reference image for an entity.
    public func tagEntity(_ entityRef: String, imageURL: URL) {
        let ps = perceptionService
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let events = try await ps.tag(entityRef: entityRef, imageURL: imageURL)
                guard !self.isShuttingDown else { return }
                self.observeWorldEvents(events)
                self.logConsole("Tagged \(entityRef)",
                                detail: "\(events.count) inferred properties")
            } catch {
                guard !self.isShuttingDown else { return }
                self.logConsole("Perception unavailable for \(entityRef)",
                                severity: .warning,
                                detail: error.localizedDescription)
            }
        }
    }

    /// 处理 AssetBrowser 在视口内放下资产的事件。如果当前光标坐标
    /// 落在视口矩形内则生成实体，否则只是清掉拖动状态。
    @discardableResult
    public func handleAssetDrop(at cursorX: Float, cursorY: Float) -> Bool {
        guard let payload = store.state.activeAssetDrag else { return false }
        defer { store.dispatch(.endAssetDrag) }
        let payloadAsset = EditorAssetCatalog.asset(for: payload.assetID)
        let dropPayload = AssetDropPayload(id: payload.assetID,
                                           name: payload.displayName,
                                           subtitle: payloadAsset?.relativePath,
                                           kind: payload.kindLabel,
                                           previewPath: payloadAsset?.kind.isTexture == true ? payloadAsset?.absolutePath : nil)
        if AssetDropRegistryHolder.current?.drop(dropPayload, atX: cursorX, y: cursorY) == true {
            logConsole("Dropped \(payload.displayName)")
            return true
        }
        guard let frame = EditorViewportDropTarget.frame,
              frame.contains(x: cursorX, y: cursorY)
        else {
            logConsole("Canceled asset drop", severity: .warning, detail: payload.displayName)
            return false
        }
        guard let asset = payloadAsset else {
            logConsole("Missing asset for drop", severity: .error, detail: payload.assetID)
            return false
        }
        guard asset.kind.isMesh else {
            logConsole("Unsupported viewport asset drop",
                       severity: .warning,
                       detail: "\(payload.displayName) is a \(asset.kind.sceneKindLabel)")
            return false
        }
        let position = dropWorldPosition(cursorX: cursorX, cursorY: cursorY, frame: frame)
        return spawnAsset(asset, at: position) != nil
    }

    /// 把视口内光标坐标投到世界 y=0 平面，作为资产落点。
    /// 摄像机指向上方或与平面平行时退化为 (0,0,0)。
    private func dropWorldPosition(cursorX: Float,
                                   cursorY: Float,
                                   frame: ViewportScreenFrame) -> SIMD3<Float> {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let camera = scene.scene.extractedRenderScene?.scene.camera
            ?? RenderCamera.fallbackPerspective

        let u = (cursorX - frame.x) / frame.width
        let v = (cursorY - frame.y) / frame.height
        let ndcX = 2 * u - 1
        let ndcY = 1 - 2 * v

        let forward = simd_normalize(camera.target - camera.eye)
        let rightRaw = simd_cross(forward, camera.up)
        guard simd_length(rightRaw) > 1e-5 else { return .zero }
        let right = simd_normalize(rightRaw)
        let up = simd_normalize(simd_cross(right, forward))

        let aspect = frame.width / frame.height
        let tanHalfFov = tanf(camera.fovYRadians * 0.5)
        let dir = simd_normalize(forward
                                 + right * (ndcX * aspect * tanHalfFov)
                                 + up * (ndcY * tanHalfFov))

        // 与 y = 0 平面相交。摄像机在平面下方或视线指向上方时退化。
        if abs(dir.y) < 1e-4 { return .zero }
        let t = -camera.eye.y / dir.y
        if t <= 0 || t > 1_000 { return .zero }
        var hit = camera.eye + dir * t
        hit.y = 0
        return hit
    }

    public func queueViewportRenderSettings(_ settings: RenderSettings) {
        queueTrackedRenderSettings(settings)
    }

    /// Single funnel for render-settings changes: bumps the generation the
    /// viewport render gate folds into its dirty signature.
    private func queueTrackedRenderSettings(_ settings: RenderSettings) {
        renderSettingsGeneration &+= 1
        lastQueuedRenderSettings = settings
        engine.queueRenderSettings(settings)
    }

    public func setViewportShadowsEnabled(_ enabled: Bool) {
        if store.state.viewportShadowsEnabled != enabled {
            store.dispatch(.setViewportShadowsEnabled(enabled))
        }
        queueTrackedRenderSettings(makeViewportRenderSettings(
            shadowsEnabled: enabled,
            shadingMode: store.state.viewportShadingMode))
        logConsole(enabled ? "Viewport shadows enabled" : "Viewport shadows disabled")
    }

    /// Switches the viewport shading / debug-view mode and re-queues render
    /// settings so the mesh shader updates its G-buffer visualization.
    public func setViewportShadingMode(_ mode: EditorViewportShadingMode) {
        if store.state.viewportShadingMode != mode {
            store.dispatch(.setViewportShadingMode(mode))
        }
        queueTrackedRenderSettings(makeViewportRenderSettings(
            shadowsEnabled: store.state.viewportShadowsEnabled,
            shadingMode: mode))
    }

    /// Transitions to a new playback state.
    /// - On `.playing`: snapshots the current scene, enables Jolt physics simulation.
    /// - On `.paused`: freezes physics (mode → off) without restoring the scene.
    /// - On `.stopped`: restores the pre-play scene snapshot and disables physics.
    public func applyPlaybackState(_ next: PlaybackState) {
        let current = store.state.playbackState
        guard current.canTransition(to: next) else { return }

        switch next {
        case .playing:
            if physicsPlaySnapshot == nil {
                physicsPlaySnapshot = scene.scene
                persistPhysicsPlaySnapshot()
            }
            scene.setAuthoringEnabled(false)
            var settings = scene.scene.physicsSettings
            settings.simulationMode = .play
            settings.backendKind = .jolt
            scene.scene.setPhysicsSettings(settings)
            store.dispatch(.setPlaybackState(.playing))
            logConsole("Physics simulation started")

        case .paused:
            scene.setAuthoringEnabled(false)
            var settings = scene.scene.physicsSettings
            settings.simulationMode = .off
            scene.scene.setPhysicsSettings(settings)
            store.dispatch(.setPlaybackState(.paused))
            logConsole("Physics simulation paused")

        case .stopped:
            AudioEngine.shared.resetPlaybackState()
            // Fallback: restore from disk if the in-memory snapshot was lost (e.g. after a crash).
            if physicsPlaySnapshot == nil {
                physicsPlaySnapshot = loadPersistedPhysicsPlaySnapshot()
            }
            let restoredPlaySnapshot: Bool
            if let snapshot = physicsPlaySnapshot {
                scene.scene = snapshot
                physicsPlaySnapshot = nil
                restoredPlaySnapshot = true
            } else {
                restoredPlaySnapshot = false
            }
            deletePersistedPhysicsPlaySnapshot()
            if !restoredPlaySnapshot {
                var settings = scene.scene.physicsSettings
                settings.simulationMode = .off
                settings.backendKind = .none
                scene.scene.setPhysicsSettings(settings)
            }
            scene.setAuthoringEnabled(true)
            scene.notifyRevisionChanged(recordHistory: false)
            store.dispatch(.setSceneRevision(scene.revision))
            store.dispatch(.setPlaybackState(.stopped))
            logConsole("Physics simulation stopped")
        }
    }

    // MARK: - Game Save

    /// Saves the current runtime scene state to the given slot.
    /// Works both in edit mode and during gameplay (captures post-physics transforms).
    @discardableResult
    public func saveGameState(slot: Int = 0) -> URL? {
        do {
            let url = GameSaveDocument.url(slot: slot, projectDirectory: projectDirectory)
            let manifest = scene.manifest(selectedEntityID: store.state.selectedEntityID)
            let doc = GameSaveDocument(slot: slot, manifest: manifest)
            try doc.write(to: url)
            logConsole("Game state saved", detail: "slot \(slot) → \(url.lastPathComponent)")
            return url
        } catch {
            logConsole("Failed to save game state",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    /// Loads a previously saved game state from the given slot.
    /// Replaces the current scene; returns true on success.
    @discardableResult
    public func loadGameState(slot: Int = 0) -> Bool {
        do {
            let url = GameSaveDocument.url(slot: slot, projectDirectory: projectDirectory)
            guard let doc = try GameSaveDocument.read(from: url) else {
                logConsole("No game save found", severity: .warning, detail: "slot \(slot)")
                return false
            }
            let result = scene.load(manifest: doc.manifest)
            guard result.error == nil else { throw result.error! }
            reportUnresolvedScriptBindings()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.setSceneRevision(scene.revision))
            logConsole("Game state loaded",
                       detail: "slot \(slot), \(result.entityCount) entities, saved \(doc.savedAt)")
            return true
        } catch {
            logConsole("Failed to load game state",
                       severity: .error,
                       detail: String(describing: error))
            return false
        }
    }

    // MARK: - Physics play snapshot persistence

    private var physicsPlaySnapshotURL: URL {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("physics-play-snapshot.json")
    }

    private func persistPhysicsPlaySnapshot() {
        guard let snapshot = physicsPlaySnapshot else { return }
        do {
            let guavaDir = physicsPlaySnapshotURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: guavaDir,
                                                    withIntermediateDirectories: true)
            let tmpAdapter = EditorSceneAdapter()
            tmpAdapter.scene = snapshot
            let manifest = tmpAdapter.manifest(selectedEntityID: store.state.selectedEntityID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: physicsPlaySnapshotURL, options: [.atomic])
        } catch {
            logConsole("Failed to persist physics play snapshot",
                       severity: .warning,
                       detail: String(describing: error))
        }
    }

    private func loadPersistedPhysicsPlaySnapshot() -> SceneRuntime? {
        guard FileManager.default.fileExists(atPath: physicsPlaySnapshotURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: physicsPlaySnapshotURL)
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let tmpAdapter = EditorSceneAdapter()
            _ = tmpAdapter.load(manifest: manifest, notify: false)
            logConsole("Restored physics play snapshot from disk (crash recovery)",
                       severity: .warning)
            return tmpAdapter.scene
        } catch {
            logConsole("Failed to load persisted physics play snapshot",
                       severity: .warning,
                       detail: String(describing: error))
            return nil
        }
    }

    private func deletePersistedPhysicsPlaySnapshot() {
        try? FileManager.default.removeItem(at: physicsPlaySnapshotURL)
    }

    private func makeViewportRenderSettings(
        shadowsEnabled: Bool,
        shadingMode: EditorViewportShadingMode
    ) -> RenderSettings {
        RenderSettings(
            stage: .r4LightingPBRShadow,
            debugViewMode: RenderSettings.DebugViewMode(rawValue: shadingMode.debugViewIndex) ?? .shaded,
            shadowSettings: RenderShadowSettings(enabled: shadowsEnabled),
            enableOffscreenViewport: true
        )
    }

    public func resetPreviewScene() {
        removeEditorAutosave()
        scene.resetToPreviewScene()
        if let selection = scene.defaultSelectionID {
            store.dispatch(.setSelectedEntity(selection))
        } else {
            store.dispatch(.setSelectedEntity(nil))
        }
        logConsole("Created new preview scene")
    }

    public func requestNewScene() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before creating a new scene.")
            return
        }
        guard hasUnsavedSceneChanges else {
            resetPreviewScene()
            return
        }
        store.dispatch(.requestClose(EditorPendingCloseRequest(action: .newScene)))
    }

    public func requestOpenSceneManifest() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before opening another scene.")
            return
        }
        guard hasUnsavedSceneChanges else {
            _ = openSceneManifest()
            return
        }
        store.dispatch(.requestClose(EditorPendingCloseRequest(action: .openScene)))
    }

    /// Opens a scene chosen by the user, deferring the actual load behind the
    /// unsaved-changes confirmation when necessary.
    public func requestOpenSceneManifest(at url: URL) {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before opening another scene.")
            return
        }
        guard hasUnsavedSceneChanges else {
            _ = openSceneManifest(at: url)
            return
        }
        store.dispatch(.requestClose(EditorPendingCloseRequest(action: .openScene,
                                                               documentPath: url.path)))
    }

    /// Exports a portable, runnable project bundle to `<projectDirectory>/export`
    /// (scene + assets + descriptor). Returns the output directory, or nil on failure.
    @discardableResult
    public func exportProject() -> URL? {
        let output = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent("export", isDirectory: true)
        do {
            let authoredOutput = authoredSceneManifest()
            let manifest = authoredOutput.manifest
            // A failed scan must fail the export. Treating it as an empty
            // catalog produces a seemingly successful build with missing assets.
            let assets = try EditorAssetCatalog.loadProject(at: projectDirectory)
            let playerExecutableURL = resolvePlayerExecutableURL()
            let descriptor = try ProjectExporter.export(manifest: manifest,
                                                        appName: exportedApplicationName,
                                                        assets: assets,
                                                        sourceProjectDirectory: URL(fileURLWithPath: projectDirectory,
                                                                                    isDirectory: true),
                                                        playerExecutableURL: playerExecutableURL,
                                                        to: output)
            if playerExecutableURL != nil {
                adHocSignExportedApplication(appName: descriptor.appName, in: output)
            } else {
                logConsole("Exported portable project data without an application",
                           severity: .warning,
                           detail: "Build GuavaPlayer or set GUAVA_PLAYER_EXECUTABLE to include a self-contained player")
            }
            logConsole("Exported project bundle",
                       detail: "\(descriptor.entityCount) entities, \(descriptor.assetCount) assets"
                           + (authoredOutput.usedPlaySnapshot ? ", authored pre-play state" : "")
                           + " → \(output.path)")
            return output
        } catch {
            logConsole("Project export failed", severity: .error, detail: String(describing: error))
            return nil
        }
    }

    @discardableResult
    public func runExportedProject(at projectURL: URL) -> Bool {
        let descriptor: ProjectExportDescriptor
        do {
            descriptor = try ProjectExporter.readDescriptor(from: projectURL)
        } catch {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: "Invalid build descriptor: \(error)")
            return false
        }
        guard descriptor.schemaVersion == ProjectExporter.schemaVersion else {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: "Unsupported build descriptor version \(descriptor.schemaVersion)")
            return false
        }
        let packagedExecutable = ProjectExporter.runnableExecutableURL(
            appName: descriptor.appName,
            in: projectURL
        )
        let executable: URL
        let arguments: [String]
        if FileManager.default.isExecutableFile(atPath: packagedExecutable.path) {
            executable = packagedExecutable
            #if os(macOS)
            arguments = []
            #else
            arguments = ["--project", projectURL.path]
            #endif
        } else if let player = resolvePlayerExecutableURL() {
            executable = player
            arguments = ["--project", projectURL.path]
        } else {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: "GuavaPlayer is not installed next to the Editor. Set GUAVA_PLAYER_EXECUTABLE to its path.")
            return false
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do {
            try process.run()
            launchedPlayerProcess = process
            logConsole("Started exported build", detail: projectURL.path)
            return true
        } catch {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: String(describing: error))
            return false
        }
    }

    private func resolvePlayerExecutableURL() -> URL? {
        let environmentOverride = ProcessInfo.processInfo.environment["GUAVA_PLAYER_EXECUTABLE"]
            .map { URL(fileURLWithPath: $0) }
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        #if os(Windows)
        let playerExecutableName = "GuavaPlayer.exe"
        #else
        let playerExecutableName = "GuavaPlayer"
        #endif
        return [
            environmentOverride,
            executableDirectory.appendingPathComponent(playerExecutableName),
        ]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func adHocSignExportedApplication(appName: String, in output: URL) {
        #if os(macOS)
        let appURL = ProjectExporter.applicationBundleURL(
            appName: appName,
            in: output
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", "--timestamp=none", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logConsole("Ad-hoc signed exported application", detail: appURL.lastPathComponent)
            } else {
                logConsole("Exported application could not be ad-hoc signed",
                           severity: .warning,
                           detail: "codesign exited with status \(process.terminationStatus)")
            }
        } catch {
            logConsole("Exported application could not be ad-hoc signed",
                       severity: .warning,
                       detail: String(describing: error))
        }
        #endif
    }

    @discardableResult
    public func saveSceneManifest() -> URL? {
        do {
            let guavaDirectory = sceneManifestURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: guavaDirectory,
                                                    withIntermediateDirectories: true)
            let authoredOutput = authoredSceneManifest()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(authoredOutput.manifest)
            try data.write(to: sceneManifestURL, options: [.atomic])
            store.dispatch(.markSceneSaved(authoredOutput.revision))
            removeEditorAutosave()
            logConsole(authoredOutput.usedPlaySnapshot
                           ? "Saved authored scene snapshot during playback"
                           : "Saved scene manifest",
                       detail: sceneManifestURL.path)
            return sceneManifestURL
        } catch {
            logConsole("Failed to save scene manifest",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    /// Returns the edit-time scene used by durable authoring outputs. Gameplay
    /// saves deliberately use the live runtime state, while scene saves and
    /// packaged builds must not capture transient physics results.
    private func authoredSceneManifest() -> (
        manifest: EditorSceneManifest,
        revision: UInt64,
        usedPlaySnapshot: Bool
    ) {
        if store.state.playbackState != .stopped,
           let physicsPlaySnapshot {
            let snapshotAdapter = EditorSceneAdapter()
            snapshotAdapter.scene = physicsPlaySnapshot
            return (
                snapshotAdapter.manifest(selectedEntityID: store.state.selectedEntityID),
                snapshotAdapter.revision,
                true
            )
        }
        return (
            scene.manifest(selectedEntityID: store.state.selectedEntityID),
            store.state.sceneRevision,
            false
        )
    }

    public func openSceneManifest() -> EditorSceneManifest? {
        openSceneManifest(clearRecoveryOnSuccess: true, logMissing: true)
    }

    /// Loads an Editor scene manifest from an explicit location. Subsequent
    /// saves still target this project's canonical `.guava` manifest.
    public func openSceneManifest(at url: URL) -> EditorSceneManifest? {
        openSceneManifest(from: url, clearRecoveryOnSuccess: true, logMissing: true)
    }

    /// Restores the normal scene and then overlays a newer autosave when the
    /// previous Editor process did not complete a save/discard workflow.
    @discardableResult
    public func restoreProjectSceneAtLaunch() -> EditorSceneManifest? {
        let saved = openSceneManifest(clearRecoveryOnSuccess: false, logMissing: false)
        let savedDate = fileModificationDate(sceneManifestURL) ?? .distantPast
        let autosaveDate = fileModificationDate(editorAutosaveURL) ?? .distantPast
        let interruptedPlayDate = fileModificationDate(physicsPlaySnapshotURL) ?? .distantPast

        if interruptedPlayDate > max(savedDate, autosaveDate) {
            if let recovered = restoreInterruptedPlaySnapshotAtLaunch() {
                return recovered
            }
        } else if interruptedPlayDate != .distantPast {
            // A newer durable save/autosave already supersedes this snapshot.
            deletePersistedPhysicsPlaySnapshot()
        }

        guard FileManager.default.fileExists(atPath: editorAutosaveURL.path) else {
            return saved
        }

        let recoveryDate = fileModificationDate(editorAutosaveURL) ?? .distantPast
        guard saved == nil || recoveryDate > savedDate else {
            removeEditorAutosave()
            return saved
        }

        do {
            guard let document = try GameSaveDocument.read(from: editorAutosaveURL) else {
                return saved
            }
            let result = scene.load(manifest: document.manifest)
            guard result.error == nil else {
                throw result.error!
            }
            reportUnresolvedScriptBindings()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.setSceneRecoveryPending(true))
            recoverySuppressedRevision = nil
            lastEditorAutosavedRevision = store.state.sceneRevision
            editorAutosaveElapsed = 0
            logConsole("Recovered autosaved scene",
                       severity: .warning,
                       detail: "\(result.entityCount) entities from \(document.savedAt); save the scene to keep it")
            return document.manifest
        } catch {
            let quarantineDetail = quarantineEditorAutosave()
            logConsole("Failed to restore autosaved scene",
                       severity: .warning,
                       detail: "\(error). \(quarantineDetail)")
            return saved
        }
    }

    private func restoreInterruptedPlaySnapshotAtLaunch() -> EditorSceneManifest? {
        do {
            let data = try Data(contentsOf: physicsPlaySnapshotURL)
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let result = scene.load(manifest: manifest)
            guard result.error == nil else { throw result.error! }
            reportUnresolvedScriptBindings()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.setSceneRecoveryPending(true))
            recoverySuppressedRevision = nil
            lastEditorAutosavedRevision = store.state.sceneRevision
            editorAutosaveElapsed = 0

            let recoveredManifest = scene.manifest(selectedEntityID: result.selectedEntityID)
            do {
                try GameSaveDocument(slot: GameSaveDocument.autoSaveSlot,
                                     manifest: recoveredManifest).write(to: editorAutosaveURL)
                deletePersistedPhysicsPlaySnapshot()
            } catch {
                logConsole("Recovered interrupted Play but could not convert its snapshot to autosave",
                           severity: .warning,
                           detail: String(describing: error))
            }
            logConsole("Recovered scene from an interrupted Play session",
                       severity: .warning,
                       detail: "\(result.entityCount) entities; save the scene to keep it")
            return recoveredManifest
        } catch {
            let quarantineDetail = quarantineInterruptedPlaySnapshot()
            logConsole("Failed to restore interrupted Play snapshot",
                       severity: .warning,
                       detail: "\(error). \(quarantineDetail)")
            return nil
        }
    }

    /// Called after an explicit "Discard" choice. It removes the recovery
    /// file and suppresses shutdown autosave for this exact scene revision.
    public func discardAutosavedScene() {
        store.dispatch(.setSceneRecoveryPending(false))
        recoverySuppressedRevision = store.state.sceneRevision
        editorAutosaveElapsed = 0
        lastEditorAutosavedRevision = nil
        do {
            if FileManager.default.fileExists(atPath: editorAutosaveURL.path) {
                try FileManager.default.removeItem(at: editorAutosaveURL)
            }
        } catch {
            logConsole("Failed to discard autosaved scene",
                       severity: .warning,
                       detail: String(describing: error))
        }
    }

    private var sceneManifestURL: URL {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("editor-scene-manifest.json")
    }

    private var editorAutosaveURL: URL {
        GameSaveDocument.url(slot: GameSaveDocument.autoSaveSlot,
                             projectDirectory: projectDirectory)
    }

    private func openSceneManifest(clearRecoveryOnSuccess: Bool,
                                   logMissing: Bool) -> EditorSceneManifest? {
        openSceneManifest(from: sceneManifestURL,
                          clearRecoveryOnSuccess: clearRecoveryOnSuccess,
                          logMissing: logMissing)
    }

    private func openSceneManifest(from sourceURL: URL,
                                   clearRecoveryOnSuccess: Bool,
                                   logMissing: Bool) -> EditorSceneManifest? {
        do {
            let data = try Data(contentsOf: sourceURL)
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let result = scene.load(manifest: manifest)
            guard result.error == nil else { throw result.error! }
            reportUnresolvedScriptBindings()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.markSceneSaved(store.state.sceneRevision))
            store.dispatch(.setSceneRecoveryPending(false))
            recoverySuppressedRevision = nil
            if clearRecoveryOnSuccess {
                removeEditorAutosave()
            }
            logConsole("Opened scene manifest",
                       detail: "\(result.entityCount) entities restored from revision \(manifest.revision) · \(sourceURL.path)")
            return manifest
        } catch CocoaError.fileReadNoSuchFile {
            if logMissing {
                logConsole("No saved scene manifest",
                           severity: .warning,
                           detail: sourceURL.path)
            }
            return nil
        } catch {
            logConsole("Failed to open scene manifest",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    private func autosaveSceneIfNeeded(elapsed: Double, force: Bool = false) {
        guard store.state.playbackState == .stopped,
              hasUnsavedSceneChanges,
              recoverySuppressedRevision != store.state.sceneRevision else {
            if !hasUnsavedSceneChanges {
                editorAutosaveElapsed = 0
            }
            return
        }
        editorAutosaveElapsed += min(max(elapsed, 0), Self.editorAutosaveInterval)
        guard force || editorAutosaveElapsed >= Self.editorAutosaveInterval,
              lastEditorAutosavedRevision != store.state.sceneRevision else { return }
        do {
            let document = GameSaveDocument(
                slot: GameSaveDocument.autoSaveSlot,
                manifest: scene.manifest(selectedEntityID: store.state.selectedEntityID)
            )
            try document.write(to: editorAutosaveURL)
            lastEditorAutosavedRevision = store.state.sceneRevision
            editorAutosaveElapsed = 0
            logConsole("Autosaved scene recovery snapshot",
                       detail: editorAutosaveURL.lastPathComponent)
        } catch {
            editorAutosaveElapsed = 0
            logConsole("Failed to autosave scene recovery snapshot",
                       severity: .warning,
                       detail: String(describing: error))
        }
    }

    private func removeEditorAutosave() {
        store.dispatch(.setSceneRecoveryPending(false))
        recoverySuppressedRevision = nil
        editorAutosaveElapsed = 0
        lastEditorAutosavedRevision = nil
        try? FileManager.default.removeItem(at: editorAutosaveURL)
    }

    private func quarantineEditorAutosave() -> String {
        guard FileManager.default.fileExists(atPath: editorAutosaveURL.path) else {
            return "The recovery file was already absent."
        }
        let quarantineURL = editorAutosaveURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: editorAutosaveURL, to: quarantineURL)
            return "The unreadable recovery file was moved to \(quarantineURL.lastPathComponent)."
        } catch {
            return "The unreadable recovery file was preserved at \(editorAutosaveURL.path) because quarantine failed: \(error)"
        }
    }

    private func quarantineInterruptedPlaySnapshot() -> String {
        guard FileManager.default.fileExists(atPath: physicsPlaySnapshotURL.path) else {
            return "The interrupted Play snapshot was already absent."
        }
        let quarantineURL = physicsPlaySnapshotURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: physicsPlaySnapshotURL, to: quarantineURL)
            return "The unreadable snapshot was moved to \(quarantineURL.lastPathComponent)."
        } catch {
            return "The unreadable snapshot was preserved at \(physicsPlaySnapshotURL.path) because quarantine failed: \(error)"
        }
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    @discardableResult
    public func reloadAssets() -> Int? {
        do {
            let assets = try EditorAssetCatalog.loadProject(at: projectDirectory)
            reloadProjectScripts(force: true)
            store.dispatch(.forceUIRefresh)
            logConsole("Reloaded assets", detail: "\(assets.count) importable files")
            return assets.count
        } catch {
            logConsole("Failed to reload assets",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    public func reloadProjectScripts(force: Bool = false) {
        do {
            guard let catalog = try projectScriptCatalogMonitor.loadIfChanged(force: force) else {
                return
            }
            let report = scene.applyProjectScriptCatalog(catalog)
            store.dispatch(.forceUIRefresh)
            if let session {
                let context = Self.workflowContext(for: store.state.workspaceMode,
                                                   scriptEntries: catalog.entries)
                let previousTask = pendingAISetupTask
                pendingAISetupTask = Task {
                    await previousTask?.value
                    await session.setWorkflowContext(context)
                }
            }
            let source = catalog.sourceURL?.path ?? "built-in catalog"
            logConsole("Reloaded script catalog",
                       detail: "\(report.registeredScriptCount) scripts (\(report.projectScriptCount) project) · \(source)")
            for diagnostic in catalog.diagnostics {
                logConsole("Script catalog: \(diagnostic.message)",
                           severity: diagnostic.severity == .error ? .error : .warning)
            }
            for unresolved in report.unresolvedBindings {
                logConsole("Unresolved script binding",
                           severity: .error,
                           detail: unresolved)
            }
        } catch {
            if scene.scriptCatalogEntries.isEmpty {
                _ = scene.applyProjectScriptCatalog(.builtIn)
                store.dispatch(.forceUIRefresh)
            }
            logConsole("Failed to reload script catalog",
                       severity: .error,
                       detail: String(describing: error))
        }
    }

    private func reportUnresolvedScriptBindings() {
        for unresolved in scene.unresolvedScriptBindingDescriptions() {
            logConsole("Unresolved script binding",
                       severity: .error,
                       detail: unresolved)
        }
    }

    public func currentRenderStats() -> RenderFrameStats {
        engine.currentRenderStats()
    }

    public func currentRenderScene() -> RenderScene {
        scene.currentRenderScene()
    }

    public func currentParticleFrameStats() -> ParticleFrameStatsResource {
        scene.currentParticleFrameStats()
    }

    public func currentParticleSimulationEventApplyReport() -> ParticleSimulationEventApplyReport {
        scene.currentParticleSimulationEventApplyReport()
    }

    public func currentParticleScalabilityState() -> ParticleScalabilityStateResource {
        scene.currentParticleScalabilityState()
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        engine.currentViewportSurfaceState()
    }

    public func currentFrameStats() -> EditorFrameStats {
        store.state.frameStats
    }

    private func makeParticleDiagnosticsSample() -> EditorParticleDiagnosticsSample {
        let stats = scene.currentParticleFrameStats()
        let eventReport = scene.currentParticleSimulationEventApplyReport()
        let renderSummary = scene.currentRenderScene().particleSummary
        let renderStats = engine.currentRenderStats()
        let nextSampleIndex = (store.state.particleDiagnosticsHistory.last?.sampleIndex ?? 0) &+ 1
        return EditorParticleDiagnosticsSample(
            sampleIndex: nextSampleIndex,
            frameIndex: store.state.frameIndex,
            simulatedDeltaTime: stats.simulatedDeltaTime,
            emitterCount: stats.emitterCount,
            activeEmitterCount: stats.activeEmitterCount,
            liveParticleCount: stats.liveParticleCount,
            liveParticleLimit: stats.liveParticleLimit,
            requestedSpawnCount: stats.requestedSpawnCount,
            spawnedParticleCount: stats.spawnedParticleCount,
            droppedSpawnCount: stats.droppedSpawnCount,
            capacityLimitedSpawnCount: stats.capacityLimitedSpawnCount,
            spawnBudgetLimitedCount: stats.spawnBudgetLimitedCount,
            spawnBudgetConsumedCount: stats.spawnBudgetConsumedCount,
            spawnBudgetLimit: stats.spawnBudgetLimit,
            eventRequestedSpawnCount: eventReport.requestedSpawnCount,
            eventDroppedSpawnCount: eventReport.droppedSpawnCount,
            droppedReadbackEventCount: eventReport.droppedReadbackEventCount,
            cpuRenderInstanceCount: renderSummary.cpuRenderInstanceCount,
            gpuRenderInstanceCount: renderSummary.gpuRenderInstanceCount,
            cpuBatchCount: renderSummary.cpuBatchCount,
            gpuBatchCount: renderSummary.gpuBatchCount,
            gpuSimulationParticleCount: renderStats.gpuParticleSimulationParticleCount,
            gpuWorkgroupCount: particleGPUWorkgroupTotal(renderStats),
            gpuSortItemCount: renderStats.gpuParticleSortItemCount,
            gpuSortPaddedItemCount: renderStats.gpuParticleSortPaddedItemCount
        )
    }

    private func particleGPUWorkgroupTotal(_ stats: RenderFrameStats) -> Int {
        stats.gpuParticleSimulationDispatchWorkgroups
            + stats.gpuParticleSortDispatchWorkgroups
            + stats.gpuParticleInstanceDispatchWorkgroups
            + stats.gpuParticleCullDispatchWorkgroups
    }

    public func currentSelectedEntityTranslation() -> SIMD3<Float>? {
        guard let entity = entityID(from: store.state.selectedEntityID) else {
            return nil
        }
        return scene.scene.localTransform(for: entity)?.translation
    }

    /// Starts a natural-language request and reports whether it was accepted.
    /// Callers use the result to avoid discarding the user's draft when a
    /// request is rejected because AI is unavailable, busy, or awaiting review.
    @discardableResult
    public func submitNaturalLanguageIntent(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        guard isSceneAuthoringEnabled else {
            store.dispatch(.setAIStatusMessage(
                "Stop simulation before submitting a scene-editing request."
            ))
            return false
        }

        if let rejection = EditorAIRequestPolicy.rejectionMessage(
            hasPendingConfirmation: store.state.pendingConfirmationRequest != nil,
            requestInFlight: activeAIRequestID != nil
        ) {
            store.dispatch(.setAIStatusMessage(rejection))
            return false
        }

        if let session {
            submitNaturalLanguageIntentWithSession(text, session: session)
            return true
        }

        let message = store.state.aiSettings.provider == .none
            ? "No AI provider configured."
            : "The configured AI provider has no usable credential."
        store.dispatch(.setAIStatusMessage(message))
        return false
    }

    private func submitNaturalLanguageIntentWithSession(_ text: String, session: Session) {
        let locale = store.state.language.lprojName
        let t0 = Date()
        store.dispatch(.setAIStatusMessage("Planning..."))
        store.dispatch(.appendChatMessage(AIChatMessage(role: .user, text: text)))
        let assistantID = UUID().uuidString
        let requestID = UUID()
        activeAIRequestID = requestID
        pendingAssistantMessageID = assistantID
        store.dispatch(.appendChatMessage(AIChatMessage(id: assistantID,
                                                        role: .assistant,
                                                        text: "",
                                                        assistantState: .thinking)))

        let capturedAid = assistantID
        let progressHandler: @Sendable (String) -> Void = { [weak self] partial in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isShuttingDown,
                      self.activeAIRequestID == requestID else { return }
                self.store.dispatch(.updateChatMessage(id: capturedAid,
                                                       assistantState: .streaming(partial)))
            }
        }

        activeAIRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeAIRequestID == requestID {
                    self.activeAIRequestID = nil
                    self.activeAIRequestTask = nil
                }
            }
            do {
                let proposal = try await session.process(
                    .naturalLanguage(text: text, locale: locale ?? "en"),
                    onProgress: progressHandler
                )
                try Task.checkCancellation()
                guard !self.isShuttingDown,
                      self.activeAIRequestID == requestID else { return }
                let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)

                guard !proposal.plan.isEmpty || !proposal.capabilityDrafts.isEmpty else {
                    self.store.dispatch(.setAIStatusMessage("No scene changes."))
                    if let aid = self.pendingAssistantMessageID {
                        let reply = proposal.plan.summary.isEmpty ? "No scene changes needed." : proposal.plan.summary
                        self.store.dispatch(.updateChatMessage(id: aid,
                                                               assistantState: .replied(reply)))
                        self.pendingAssistantMessageID = nil
                    }
                    await session.recordOutcome(toolUseID: proposal.toolUseID,
                                                content: "Acknowledged.",
                                                proposalID: proposal.id)
                    return
                }

                let containsPluginDraft = proposal.capabilityDrafts.contains {
                    $0.sourcePluginID != nil
                }
                let transaction: TransactionIR
                if containsPluginDraft {
                    guard let executor = self.pluginCapabilityExecutor else {
                        throw EditorPluginCapabilityError.pluginNotEnabled(
                            proposal.capabilityDrafts.compactMap(\.sourcePluginID).first ?? "unknown"
                        )
                    }
                    guard let snapshot = proposal.capabilityExposureSnapshot else {
                        throw EditorPluginCapabilityError.missingExposureSnapshot
                    }
                    let revision = self.scene.revision
                    let querySnapshots = try self.makePluginQuerySnapshots(
                        for: proposal.capabilityDrafts,
                        sceneRevision: revision
                    )
                    transaction = try executor.buildTransaction(
                        summary: proposal.plan.summary,
                        reasoning: proposal.plan.reasoning,
                        drafts: proposal.capabilityDrafts,
                        snapshot: snapshot,
                        scene: self.scene.scene,
                        currentSceneRevision: revision,
                        querySnapshots: querySnapshots,
                        approvalPolicy: proposal.approvalPolicy
                    )
                } else {
                    transaction = try SceneEditPlanExecutor().buildTransaction(
                        from: proposal.plan,
                        scene: self.scene.scene,
                        baseSceneRevision: proposal.baseSceneRevision,
                        approvalPolicy: proposal.approvalPolicy,
                        exposureSnapshot: proposal.capabilityExposureSnapshot
                    )
                }
                self.logConsole("AI inference: \(latencyMs)ms", detail: proposal.plan.summary)
                self.pendingSessionProposal = proposal
                try self.submitPlanTransaction(
                    transaction,
                    capabilityContext: self.makeCapabilityInvocationContext(
                        defaultSource: .ai,
                        defaultConfidence: proposal.confidence
                    )
                )
            } catch {
                guard !self.isShuttingDown,
                      self.activeAIRequestID == requestID else { return }
                let message = error.localizedDescription
                self.pendingSessionProposal = nil
                self.store.dispatch(.setAIStatusMessage(message))
                if let aid = self.pendingAssistantMessageID {
                    self.store.dispatch(.updateChatMessage(id: aid,
                                                           assistantState: .failed(message)))
                    self.pendingAssistantMessageID = nil
                }
            }
        }
    }

    private func submitPlanTransaction(_ transaction: TransactionIR,
                                       capabilityContext: CapabilityInvocationContext? = nil) throws {
        _ = try runPlanTransaction(transaction, capabilityContext: capabilityContext)
    }

    @discardableResult
    private func runPlanTransaction(_ transaction: TransactionIR,
                                    capabilityContext: CapabilityInvocationContext? = nil) throws -> CapabilityInvocationResult {
        guard store.state.pendingConfirmationRequest == nil else {
            throw EditorPlanSubmissionError.pendingConfirmation
        }
        let targetEntityIDs = referencedExistingEntityIDs(in: transaction)
        let lockedEntityIDs = targetEntityIDs.filter(scene.isEntityLocked).sorted()
        guard lockedEntityIDs.isEmpty else {
            throw EditorPlanSubmissionError.lockedEntities(lockedEntityIDs)
        }

        var context = makeExecutionContext()
        let result = try intentCoordinator.submitPlan(transaction,
                                                      executionContext: &context,
                                                      capabilityContext: capabilityContext)
        if result.disposition == .confirmationRequested {
            pendingConfirmationTargetEntityIDs = targetEntityIDs
        }
        applyInvocationResult(result, executionContext: &context)
        return result
    }

    /// Collects every existing entity whose state or hierarchy the transaction
    /// directly references. Parent IDs matter as well: spawning or moving a child
    /// changes the locked parent's hierarchy even when the child itself is new.
    private func referencedExistingEntityIDs(in transaction: TransactionIR) -> Set<UInt64> {
        var result = Set<UInt64>()

        func insertParent(of rawID: UInt64) {
            guard let entity = entityID(from: rawID),
                  scene.scene.contains(entity),
                  let parent = scene.scene.parent(of: entity) else { return }
            result.insert(parent.rawValue)
        }

        for operation in transaction.operations {
            guard case let .scene(mutation) = operation else { continue }
            if let entityID = mutation.entityID {
                result.insert(entityID)
            }
            switch mutation {
            case let .spawnImportedMeshEntity(_, _, _, _, parentID),
                 let .spawnEmptyEntity(_, _, parentID),
                 let .spawnLightEntity(_, _, _, _, _, _, _, parentID),
                 let .spawnCameraEntity(_, _, _, parentID):
                if let parentID { result.insert(parentID) }
            case let .moveEntity(entityID, parentID, _):
                insertParent(of: entityID)
                if let parentID { result.insert(parentID) }
            case let .deleteEntity(entityID):
                insertParent(of: entityID)
                if let entity = self.entityID(from: entityID), scene.scene.contains(entity) {
                    result.formUnion(scene.scene.children(of: entity).map(\.rawValue))
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Undo / Redo

    public var canUndo: Bool { scene.canUndoEdit }
    public var canRedo: Bool { scene.canRedoEdit }

    public func undo() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before undoing scene edits.")
            return
        }
        guard scene.undoEdit() else { return }
        validateSelectionAfterHistoryNavigation()
        store.dispatch(.setAIStatusMessage("Undone"))
        logConsole("Undo applied", severity: .info)
    }

    public func redo() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before redoing scene edits.")
            return
        }
        guard scene.redoEdit() else { return }
        validateSelectionAfterHistoryNavigation()
        store.dispatch(.setAIStatusMessage("Redone"))
        logConsole("Redo applied", severity: .info)
    }

    private func reportSceneAuthoringUnavailable(_ message: String) {
        store.dispatch(.setAIStatusMessage(message))
        logConsole(message, severity: .warning)
    }

    private func validateSelectionAfterHistoryNavigation() {
        let selectedID = store.state.selectedEntityID
        if scene.entitySummary(id: selectedID) == nil {
            store.dispatch(.setSelectedEntity(scene.roots.first?.id))
        }
        displayInvalidationHandler?()
    }

    public func submitSpawnEntityIntent(label: String,
                                        position: SIMD3<Float>) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = trimmed.isEmpty ? "AI Entity" : trimmed
        let intent = IntentIR(verb: "scene.spawn_entity",
                              summary: "Spawn scene entity",
                              arguments: [
                                "label": .string(resolvedLabel),
                                "position": .vec3(IntentVector3(position)),
                              ],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitRenameSelectedEntityIntent(name: String) {
        guard let selected = store.state.selectedEntityID,
              scene.entitySummary(id: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before renaming it."))
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.dispatch(.setAIStatusMessage("Enter a name before renaming the selection."))
            return
        }

        let intent = IntentIR(verb: "scene.set_name",
                              summary: "Rename selected entity",
                              targetObjectIDs: ["scene:\(selected)"],
                              arguments: ["name": .string(trimmed)],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitDuplicateSelectedEntityIntent() {
        guard let selected = store.state.selectedEntityID,
              scene.entitySummary(id: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before duplicating it."))
            return
        }

        let intent = IntentIR(verb: "scene.duplicate_entity",
                              summary: "Duplicate selected entity",
                              targetObjectIDs: ["scene:\(selected)"],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitDeleteSelectedEntityIntent() {
        guard let selected = store.state.selectedEntityID,
              scene.entitySummary(id: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before deleting it."))
            return
        }
        let intent = IntentIR(verb: "scene.delete_entity",
                              summary: "Delete selected entity",
                              targetObjectIDs: ["scene:\(selected)"],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitSetTransformIntent(translation: SIMD3<Float>) {
        guard let selected = store.state.selectedEntityID,
              entityID(from: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before setting its transform."))
            return
        }
        let intent = IntentIR(verb: "scene.set_transform",
                              summary: "Set selected transform",
                              targetObjectIDs: ["scene:\(selected)"],
                              arguments: ["translation": .vec3(IntentVector3(translation))],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func resolvePendingConfirmation(pickedOptionIDsByQuestionID selections: [String: String]) {
        guard let request = store.state.pendingConfirmationRequest,
              !request.questions.isEmpty else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }

        var answers: [ConfirmationAnswer] = []
        for question in request.questions {
            guard let pickedOptionID = selections[question.id],
                  question.options.contains(where: { $0.id == pickedOptionID }) else {
                store.dispatch(.setAIStatusMessage(
                    "Choose an option for every confirmation item before continuing."
                ))
                return
            }
            let normalized = pickedOptionID.lowercased()
            let outcome: ConfirmationAnswerOutcome = ["skip", "discard", "reject", "deny", "cancel"]
                .contains(normalized) ? .skipped : .accepted
            answers.append(ConfirmationAnswer(questionID: question.id,
                                              outcome: outcome,
                                              pickedOptionID: pickedOptionID))
        }
        let resolution = ConfirmationResolution(batchID: request.batchID,
                                                correlationID: request.correlationID,
                                                answers: answers,
                                                userID: "local-editor",
                                                partial: false)
        resolvePendingConfirmation(resolution)
    }

    private func resolvePendingConfirmation(_ resolution: ConfirmationResolution) {
        let lockedEntityIDs = pendingConfirmationTargetEntityIDs
            .filter(scene.isEntityLocked)
            .sorted()
        let acceptsAnyMutation = resolution.answers.contains { $0.outcome == .accepted }
        guard lockedEntityIDs.isEmpty || !acceptsAnyMutation else {
            store.dispatch(.setAIStatusMessage(
                "The pending plan targets locked entities: \(lockedEntityIDs.map(String.init).joined(separator: ", ")). "
                    + "Discard this confirmation, unlock them, and submit the action again."
            ))
            return
        }
        var context = makeExecutionContext()
        do {
            let result = try intentCoordinator.resolvePlanConfirmation(resolution,
                                                                       executionContext: &context)
            applyInvocationResult(result, executionContext: &context)
        } catch {
            store.dispatch(.setAIStatusMessage(error.localizedDescription))
        }
    }

    public func resolvePendingConfirmation(pickedOptionID: String) {
        guard let request = store.state.pendingConfirmationRequest else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }
        let selections: [String: String] = Dictionary(uniqueKeysWithValues: request.questions.compactMap { question in
            guard question.options.contains(where: { $0.id == pickedOptionID }) else { return nil }
            return (question.id, pickedOptionID)
        })
        resolvePendingConfirmation(pickedOptionIDsByQuestionID: selections)
    }

    public func acceptPendingConfirmation() {
        guard let request = store.state.pendingConfirmationRequest else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }
        let selections: [String: String] = Dictionary(uniqueKeysWithValues: request.questions.compactMap { question in
            let optionID = question.defaultOptionID ?? question.options.first?.id
            return optionID.map { (question.id, $0) }
        })
        resolvePendingConfirmation(pickedOptionIDsByQuestionID: selections)
    }

    public func skipPendingConfirmation() {
        guard let request = store.state.pendingConfirmationRequest else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }
        let answers = request.questions.map { question in
            let optionID = question.options.first(where: {
                ["skip", "discard", "reject", "deny", "cancel"].contains($0.id.lowercased())
            })?.id
            return ConfirmationAnswer(questionID: question.id,
                                      outcome: .skipped,
                                      pickedOptionID: optionID)
        }
        resolvePendingConfirmation(ConfirmationResolution(
            batchID: request.batchID,
            correlationID: request.correlationID,
            answers: answers,
            userID: "local-editor",
            partial: false
        ))
    }

    private func handlePlatformEvent(_ event: InputEvent) {
        switch event {
        case let .mouseButtonDown(button):
            if EditorViewportInputController.shared.hasActivePointerSession,
               EditorViewportDropTarget.frame?.contains(x: button.x, y: button.y) != true {
                scene.endInteractiveEditHistoryGroup()
                EditorGizmoController.shared.clearDrag()
                EditorViewportInputController.shared.endPointerSession()
            }
        case let .mouseButtonUp(button):
            if EditorViewportInputController.shared.hasActivePointerSession,
               EditorViewportDropTarget.frame?.contains(x: button.x, y: button.y) != true {
                scene.endInteractiveEditHistoryGroup()
                EditorGizmoController.shared.clearDrag()
                EditorViewportInputController.shared.endPointerSession()
            }
        case .windowFocusGained:
            store.dispatch(.setWindowFocused(true))
        case .windowFocusLost:
            store.dispatch(.setWindowFocused(false))
            scene.endInteractiveEditHistoryGroup()
            EditorGizmoController.shared.clearDrag()
            EditorViewportInputController.shared.reset()
        case .windowMinimized:
            store.dispatch(.setWindowMinimized(true))
            scene.endInteractiveEditHistoryGroup()
            EditorGizmoController.shared.clearDrag()
            EditorViewportInputController.shared.reset()
        case .windowRestored:
            store.dispatch(.setWindowMinimized(false))
            store.dispatch(.setWindowOccluded(false))
        case .windowOccluded:
            store.dispatch(.setWindowOccluded(true))
        case .windowExposed:
            store.dispatch(.setWindowOccluded(false))
        default:
            break
        }
    }

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
        pendingAssistantMessageID = nil
        let newSession = Self.makeSession(
            for: settings,
            pluginCapabilityExecutor: pluginCapabilityExecutor,
            pluginQuerySnapshotProvider: makePluginQuerySnapshotProvider()
        )
        if oldSession != nil || newSession != nil {
            let worldContext = self.aiWorldContext
            let ctx = Self.workflowContext(for: store.state.workspaceMode,
                                           scriptEntries: scene.scriptCatalogEntries)
            let bus = self.observationBus
            let mem = self.contextMemoryStore
            let previousTask = pendingAISetupTask
            pendingAISetupTask = Task {
                await previousTask?.value
                await oldSession?.cancelActiveRun()
                if let newSession {
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

    // MARK: - Isolated AI plugins

    /// Inspects WIT, manifest metadata, and Component exports without enabling
    /// or exposing the plugin. The returned value is what the UI must show
    /// before constructing an explicit authorization record.
    @MainActor
    public func inspectPlugin(at pluginURL: URL) throws -> PluginInspection {
        try resolvedPluginHostClient().inspectPlugin(at: pluginURL)
    }

    /// Call only after the user has approved the inspection shown by the UI.
    /// Any code, WIT, permission, or schema change makes this record invalid.
    public func makePluginAuthorization(
        afterUserApprovalOf inspection: PluginInspection,
        at date: Date = Date()
    ) throws -> PluginAuthorizationRecord {
        try PluginAuthorizationRecord(inspection: inspection, authorisedAt: date)
    }

    /// A stored record is reusable only when every current inspection field is
    /// identical. Merely finding a record never loads or exposes the plugin.
    public func storedPluginAuthorization(
        for inspection: PluginInspection
    ) -> PluginAuthorizationRecord? {
        pluginAuthorizationStore.authorization(for: inspection)
    }

    /// Loads an already-authorized package into the isolated host, rebuilds the
    /// one Registry used by Editor AI and MCP, and invalidates every old Draft.
    @MainActor
    @discardableResult
    public func enablePlugin(
        at pluginURL: URL,
        authorization: PluginAuthorizationRecord
    ) async throws -> PluginInspection {
        guard pluginBindings[authorization.pluginID] == nil else {
            throw EditorPluginCapabilityError.pluginAlreadyEnabled(authorization.pluginID)
        }
        let client = try resolvedPluginHostClient()
        let binding = try await Task.detached(priority: .userInitiated) {
            try client.loadPlugin(at: pluginURL, authorization: authorization)
        }.value
        var nextBindings = pluginBindings
        nextBindings[binding.pluginID] = binding
        let executor: PluginCapabilityExecutor
        do {
            executor = try PluginCapabilityExecutor(
                bindings: nextBindings.values.sorted { $0.pluginID < $1.pluginID },
                invoker: client
            )
            try pluginAuthorizationStore.record(authorization)
        } catch {
            _ = try? await Task.detached(priority: .userInitiated) {
                try client.unloadPlugin(at: pluginURL)
            }.value
            throw error
        }
        pluginBindings = nextBindings
        await activatePluginExecutor(executor)
        return binding.inspection
    }

    @MainActor
    public func disablePlugin(id pluginID: String) async throws {
        guard let binding = pluginBindings[pluginID] else {
            throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
        }
        var unloadError: Error?
        do {
            let client = pluginHostClient
            let pluginURL = URL(fileURLWithPath: binding.pluginPath,
                                isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                try client?.unloadPlugin(at: pluginURL)
            }.value
        } catch {
            unloadError = error
        }
        pluginBindings.removeValue(forKey: pluginID)
        let executor: PluginCapabilityExecutor?
        do {
            if pluginBindings.isEmpty {
                executor = nil
            } else if let client = pluginHostClient {
                executor = try PluginCapabilityExecutor(
                    bindings: pluginBindings.values.sorted { $0.pluginID < $1.pluginID },
                    invoker: client
                )
            } else {
                executor = nil
            }
        } catch {
            // Rebuilding the remaining registry is part of the trust boundary. If it
            // cannot be proven consistent, discard every in-memory plugin binding.
            pluginBindings.removeAll()
            await activatePluginExecutor(nil)
            throw error
        }
        await activatePluginExecutor(executor)
        if let unloadError { throw unloadError }
    }

    @MainActor
    public func revokePluginAuthorization(id pluginID: String) async throws {
        var disableError: Error?
        if pluginBindings[pluginID] != nil {
            do {
                try await disablePlugin(id: pluginID)
            } catch {
                disableError = error
            }
        }
        try pluginAuthorizationStore.remove(pluginID: pluginID)
        if let disableError { throw disableError }
    }

    public func enabledPluginInspections() -> [PluginInspection] {
        pluginBindings.values.map(\.inspection).sorted {
            $0.manifest.id < $1.manifest.id
        }
    }

    public var isPluginHostAvailable: Bool {
        trustedPluginHostExecutableURL != nil
    }

    /// Starts the explicit Settings-panel flow. Inspection does not load the
    /// component and the package URL is retained only in private process
    /// memory, never in observable/project state.
    @MainActor
    public func inspectPluginForManagement(at pluginURL: URL) async {
        pendingPluginApproval = nil
        publishPluginManagement(phase: .inspecting,
                                candidate: nil,
                                message: nil)
        do {
            let client = try resolvedPluginHostClient()
            let inspection = try await Task.detached(priority: .userInitiated) {
                try client.inspectPlugin(at: pluginURL)
            }.value
            let reusable = storedPluginAuthorization(for: inspection) != nil
            pendingPluginApproval = PendingPluginApproval(
                packageURL: pluginURL.standardizedFileURL,
                inspection: inspection
            )
            publishPluginManagement(
                phase: .awaitingAuthorization,
                candidate: EditorPluginInspectionSummary(
                    inspection: inspection,
                    hasReusableAuthorization: reusable
                ),
                message: reusable
                    ? "This exact plugin build was previously authorized. Review it before enabling."
                    : "Review the code hashes, imports, access level, and capabilities before authorizing."
            )
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: nil,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    /// Called only by an explicit user action after the inspection summary is
    /// visible. The host re-inspects the package during load, so a file change
    /// between review and approval fails closed.
    @MainActor
    public func authorizeAndEnableInspectedPlugin() async {
        guard let pending = pendingPluginApproval else {
            publishPluginManagement(
                phase: .failed,
                candidate: nil,
                message: EditorPluginCapabilityError.noPendingPluginApproval.localizedDescription
            )
            return
        }
        let candidate = EditorPluginInspectionSummary(
            inspection: pending.inspection,
            hasReusableAuthorization: storedPluginAuthorization(for: pending.inspection) != nil
        )
        publishPluginManagement(phase: .enabling,
                                candidate: candidate,
                                message: nil)
        do {
            let authorization = try storedPluginAuthorization(for: pending.inspection)
                ?? makePluginAuthorization(afterUserApprovalOf: pending.inspection)
            let enabledInspection = try await enablePlugin(
                at: pending.packageURL,
                authorization: authorization
            )
            pendingPluginApproval = nil
            publishPluginManagement(
                phase: .idle,
                candidate: nil,
                message: "Enabled plugin '\(enabledInspection.manifest.name)'."
            )
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: candidate,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    @MainActor
    public func cancelPluginApproval() {
        pendingPluginApproval = nil
        publishPluginManagement(phase: .idle,
                                candidate: nil,
                                message: nil)
    }

    @MainActor
    public func disablePluginFromManagement(id pluginID: String) async {
        do {
            try await disablePlugin(id: pluginID)
            publishPluginManagement(phase: .idle,
                                    candidate: store.state.pluginManagement.candidate,
                                    message: "Disabled plugin '\(pluginID)'.")
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: store.state.pluginManagement.candidate,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    @MainActor
    public func revokePluginFromManagement(id pluginID: String) async {
        do {
            try await revokePluginAuthorization(id: pluginID)
            if pendingPluginApproval?.inspection.manifest.id == pluginID {
                pendingPluginApproval = nil
            }
            publishPluginManagement(phase: .idle,
                                    candidate: nil,
                                    message: "Revoked authorization for plugin '\(pluginID)'.")
        } catch {
            publishPluginManagement(phase: .failed,
                                    candidate: store.state.pluginManagement.candidate,
                                    message: Self.pluginManagementErrorMessage(error))
        }
    }

    @MainActor
    private func publishPluginManagement(
        phase: EditorPluginManagementPhase,
        candidate: EditorPluginInspectionSummary?,
        message: String?
    ) {
        let enabled = pluginBindings.values.map {
            EditorPluginInspectionSummary(inspection: $0.inspection,
                                          hasReusableAuthorization: true)
        }
        store.dispatch(.setPluginManagementState(
            EditorPluginManagementState(phase: phase,
                                        candidate: candidate,
                                        enabled: enabled,
                                        message: message)
        ))
        displayInvalidationHandler?()
    }

    private static func pluginManagementErrorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    @MainActor
    private func resolvedPluginHostClient() throws -> PluginHostProcessClient {
        if let existing = pluginHostClient { return existing }
        guard let resolvedURL = trustedPluginHostExecutableURL else {
            throw EditorPluginCapabilityError.pluginHostUnavailable
        }
        let client = PluginHostProcessClient(executableURL: resolvedURL)
        client.onInvalidation = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.invalidatePluginsAfterHostRestart()
                }
            }
        }
        pluginHostClient = client
        return client
    }

    @MainActor
    private func invalidatePluginsAfterHostRestart() async {
        pluginBindings.removeAll()
        pendingPluginApproval = nil
        await activatePluginExecutor(nil)
        store.dispatch(.setPluginManagementState(
            EditorPluginManagementState(
                phase: .failed,
                message: "PluginHost restarted. Enabled plugins and pending approvals were invalidated."
            )
        ))
        store.dispatch(.setAIStatusMessage(
            "PluginHost restarted. Plugin capabilities and pending plans were invalidated."
        ))
    }

    @MainActor
    private func activatePluginExecutor(_ executor: PluginCapabilityExecutor?) async {
        await pendingAISetupTask?.value
        pendingAISetupTask = nil
        pluginCapabilityExecutor = executor
        let settings = store.state.capabilitySettings
        intentCoordinator.configureCapabilityPlanner(
            Self.makeCapabilityInvocationPlanner(for: settings,
                                                 pluginCapabilityExecutor: executor)
        )
        await mcpCapabilitySessions.replaceRegistry(
            executor?.registry ?? .aiDefault,
            exposurePolicy: executor?.exposurePolicy
                ?? CapabilityExposurePolicy(activeReleasePhase: .stable,
                                            allowedDomains: ["scene"],
                                            maximumCapabilities: 16),
            pluginAuthorities: executor?.pluginAuthorities ?? [:]
        )

        let oldSession = session
        cancelActiveAIRequest()
        await oldSession?.cancelActiveRun()
        let world = await aiWorldContext.snapshot()
        let nextSession = Self.makeSession(
            for: store.state.aiSettings,
            initialWorldView: world,
            pluginCapabilityExecutor: executor,
            pluginQuerySnapshotProvider: makePluginQuerySnapshotProvider()
        )
        session = nextSession
        if let nextSession {
            await nextSession.setObservationBus(observationBus)
            await nextSession.setContextMemory(contextMemoryStore)
            await nextSession.setWorkflowContext(Self.workflowContext(
                for: store.state.workspaceMode,
                scriptEntries: scene.scriptCatalogEntries
            ))
        }
        pendingSessionProposal = nil
        pendingAssistantMessageID = nil
        store.dispatch(.clearChatHistory)
    }

    /// Removes the stored API key for the current provider and disables AI.
    @discardableResult
    public func clearAIKey() -> Bool {
        do {
            try AIKeychain.delete(provider: store.state.aiSettings.provider)
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
        pendingAssistantMessageID = nil
        var settings = store.state.aiSettings
        settings.provider = .none
        store.dispatch(.setAISettings(settings))
        return true
    }

    private func cancelActiveAIRequest() {
        activeAIRequestID = nil
        activeAIRequestTask?.cancel()
        activeAIRequestTask = nil
        pendingSessionProposal = nil
    }

    /// Returns `true` if a non-empty API key is stored for the current provider.
    public func hasStoredAIKey(for provider: EditorAIProvider? = nil) -> Bool {
        AIKeychain.hasKey(for: provider ?? store.state.aiSettings.provider)
    }

    public func aiCredentialSource(
        for provider: EditorAIProvider? = nil
    ) -> AICredentialSource? {
        AIKeychain.credentialSource(for: provider ?? store.state.aiSettings.provider)
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
        case .level:
            return .game(GameWorkflowContext(levelPhase: .blockout,
                                            gameplayIntent: intent,
                                            targetExperience: "Interactive level editing",
                                            knownConstraints: constraints))
        case .modeling:
            return .game(GameWorkflowContext(levelPhase: .polish,
                                            gameplayIntent: intent,
                                            targetExperience: "Asset creation and modeling",
                                            knownConstraints: constraints))
        case .animation:
            return .game(GameWorkflowContext(levelPhase: .polish,
                                            gameplayIntent: intent,
                                            targetExperience: "Animation authoring",
                                            knownConstraints: constraints))
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
            return Session(config: .anthropic(apiKey: key, model: settings.model,
                                              autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView,
                           pluginCapabilityExecutor: pluginCapabilityExecutor,
                           pluginQuerySnapshotProvider: pluginQuerySnapshotProvider)
        case .openai:
            guard let key = AIKeychain.load(provider: .openai) else { return nil }
            return Session(config: .openAIResponses(apiKey: key, model: settings.model,
                                                    autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView,
                           pluginCapabilityExecutor: pluginCapabilityExecutor,
                           pluginQuerySnapshotProvider: pluginQuerySnapshotProvider)
        case .deepseek:
            guard let key = AIKeychain.load(provider: .deepseek) else { return nil }
            return Session(config: .deepSeek(apiKey: key, model: settings.model,
                                             autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView,
                           pluginCapabilityExecutor: pluginCapabilityExecutor,
                           pluginQuerySnapshotProvider: pluginQuerySnapshotProvider)
        }
    }

    private func makePluginQuerySnapshotProvider() -> PluginQuerySnapshotProvider? {
        guard pluginCapabilityExecutor != nil else { return nil }
        return { [weak self] pluginID, revision in
            guard let self else {
                throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
            }
            return try await MainActor.run {
                try self.makePluginQuerySnapshot(pluginID: pluginID,
                                                 sceneRevision: revision)
            }
        }
    }

    private func makePluginQuerySnapshot(
        pluginID: String,
        sceneRevision: UInt64
    ) throws -> PluginQuerySnapshot? {
        guard let executor = pluginCapabilityExecutor else {
            throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
        }
        let imports = try executor.requiredImports(forPluginID: pluginID)
        guard !imports.isEmpty else { return nil }
        guard scene.revision == sceneRevision else {
            throw EditorPluginCapabilityError.sceneRevisionChanged(
                expected: sceneRevision,
                actual: scene.revision
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var scenePayload: Data?
        var selectionPayload: Data?
        var assetPayload: Data?

        if imports.contains(.sceneQuery) {
            let snapshot = SceneSemanticEncoder().encode(
                scene.scene,
                selectedEntityID: store.state.selectedEntityID,
                workspaceMode: store.state.workspaceMode.rawValue,
                localeIdentifier: nil
            )
            scenePayload = try encoder.encode(snapshot)
        }
        if imports.contains(.selectionQuery) {
            let selected = store.state.selectedEntityID.map { ["scene:\($0)"] } ?? []
            selectionPayload = try JSONSerialization.data(
                withJSONObject: ["selected": selected],
                options: [.sortedKeys]
            )
        }
        if imports.contains(.assetMetadataQuery) {
            let assets: [[String: Any]] = EditorAssetCatalog.entries().map { asset in
                [
                    "id": asset.id,
                    "name": asset.name,
                    "relative_path": asset.relativePath,
                    "kind": String(describing: asset.kind),
                    "mesh_index": asset.meshIndex,
                ]
            }
            assetPayload = try JSONSerialization.data(
                withJSONObject: ["assets": assets],
                options: [.sortedKeys]
            )
        }
        let snapshot = PluginQuerySnapshot(sceneRevision: sceneRevision,
                                           scene: scenePayload,
                                           selection: selectionPayload,
                                           assetMetadata: assetPayload)
        try snapshot.validate(for: imports)
        return snapshot
    }

    private func makePluginQuerySnapshots(
        for drafts: [CapabilityInvocationDraft],
        sceneRevision: UInt64
    ) throws -> [String: PluginQuerySnapshot] {
        var result: [String: PluginQuerySnapshot] = [:]
        for pluginID in Set(drafts.compactMap(\.sourcePluginID)).sorted() {
            if let snapshot = try makePluginQuerySnapshot(pluginID: pluginID,
                                                          sceneRevision: sceneRevision) {
                result[pluginID] = snapshot
            }
        }
        return result
    }

    static func makeCapabilityInvocationPlanner(
        for settings: EditorCapabilitySettings,
        pluginCapabilityExecutor: PluginCapabilityExecutor? = nil
    ) -> CapabilityInvocationPlanner {
        let gate = ReleasePhaseGate(activePhase: settings.releasePhase.runtimePhase)
        return pluginCapabilityExecutor?.makeInvocationPlanner(gate: gate)
            ?? CapabilityInvocationPlanner(gate: gate)
    }

    private func submitResolvedIntent(_ intent: IntentIR) {
        do {
            let transaction = try intentTransactionBuilder.buildTransaction(from: intent,
                                                                            context: makeIntentTransactionBuildContext())
            try submitPlanTransaction(
                transaction,
                capabilityContext: makeCapabilityInvocationContext(
                    defaultSource: intent.source,
                    defaultConfidence: intent.confidence,
                    defaultEvidence: intent.evidence
                )
            )
        } catch EditorPlanSubmissionError.pendingConfirmation {
            store.dispatch(.setAIStatusMessage(
                EditorAIRequestPolicy.pendingConfirmationMessage
            ))
        } catch {
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings([]))
            store.dispatch(.setAIStatusMessage(error.localizedDescription))
        }
    }

    private func makeIntentTransactionBuildContext() -> IntentTransactionBuildContext {
        IntentTransactionBuildContext(sceneRuntime: scene.scene,
                                      selectedEntityID: store.state.selectedEntityID,
                                      defaultSpawnMeshIndex: defaultSpawnMeshIndex())
    }

    private func makeCapabilityInvocationContext(defaultSource: IntentSource = .system,
                                                 defaultConfidence: Double = 1.0,
                                                 defaultEvidence: [IntentEvidence] = []) -> CapabilityInvocationContext {
        CapabilityInvocationContext(sceneRuntime: scene.scene,
                                    selectedEntityID: store.state.selectedEntityID,
                                    isSceneEditable: store.state.playbackState == .stopped,
                                    defaultSource: defaultSource,
                                    defaultConfidence: defaultConfidence,
                                    defaultEvidence: defaultEvidence)
    }

    private func applyInvocationResult(_ result: CapabilityInvocationResult,
                                       executionContext: inout TransactionExecutionContext) {
        if let updatedScene = executionContext.sceneRuntime {
            scene.scene = updatedScene
            scene.notifyRevisionChanged()
        }

        switch result.disposition {
        case .applied:
            pendingConfirmationTargetEntityIDs.removeAll()
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings(result.warnings))
            updateSelection(after: result.applyResult)
            store.dispatch(.setAIStatusMessage("Applied \(result.transactionID)"))
            if let aid = pendingAssistantMessageID {
                let planSummary = pendingSessionProposal?.plan.summary ?? ""
                let appliedSummary = planSummary.isEmpty ? "Applied" : planSummary
                store.dispatch(.updateChatMessage(id: aid, assistantState: .applied(summary: appliedSummary)))
                pendingAssistantMessageID = nil
            }
            if var edit = result.applyResult?.edit {
                // Enrich provenance with the proposal that generated this edit.
                if let proposal = pendingSessionProposal {
                    edit.provenance.proposalID = proposal.id
                    let acceptedStepIDs = (0..<proposal.plan.steps.count).map { "step_\($0)" }
                    if let session {
                        Task {
                            _ = try? await session.process(
                                .userCorrection(proposalID: proposal.id,
                                               acceptedStepIDs: acceptedStepIDs,
                                               rejectedStepIDs: [])
                            )
                        }
                    }
                    pendingSessionProposal = nil
                }
                do {
                    try editLog.append(edit)
                } catch {
                    logConsole("Failed to record applied edit",
                               severity: .error,
                               detail: "\(edit.id): \(error)")
                }
            }
            if let events = result.applyResult?.worldEvents, !events.isEmpty {
                observeWorldEvents(events)
            }
        case .confirmationRequested:
            store.dispatch(.setPendingConfirmationRequest(result.confirmationRequest))
            store.dispatch(.setAIWarnings(result.warnings))
            store.dispatch(.setAIStatusMessage("Confirmation required for \(result.transactionID)"))
            if let aid = pendingAssistantMessageID {
                let prompt = result.confirmationRequest?.questions.first?.promptShort ?? "Confirmation required"
                store.dispatch(.updateChatMessage(id: aid, assistantState: .pendingConfirmation(summary: prompt)))
            }
        case .discarded:
            pendingConfirmationTargetEntityIDs.removeAll()
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings(result.warnings))
            store.dispatch(.setAIStatusMessage("Discarded \(result.transactionID)"))
            if let aid = pendingAssistantMessageID {
                store.dispatch(.updateChatMessage(id: aid, assistantState: .discarded))
                pendingAssistantMessageID = nil
            }
            if let proposal = pendingSessionProposal {
                if let session {
                    Task { await session.recordOutcome(
                        toolUseID: proposal.toolUseID,
                        content: "User rejected this plan.",
                        proposalID: proposal.id
                    ) }
                }
                pendingSessionProposal = nil
            }
        }
    }

    private func makeExecutionContext() -> TransactionExecutionContext {
        TransactionExecutionContext(sceneRuntime: scene.scene,
                                    observationBus: observationBus,
                                    eventOrigin: EventOrigin(process: .editor,
                                                             host: "local-editor",
                                                             user: "local-user"))
    }

    private func updateSelection(after applyResult: TransactionApplyResult?) {
        if let created = applyResult?.createdEntityIDs.first {
            store.dispatch(.setSelectedEntity(created))
            return
        }
        guard let applyResult else { return }
        if let selected = store.state.selectedEntityID,
           applyResult.deletedEntityIDs.contains(selected) {
            store.dispatch(.setSelectedEntity(nil))
        }
    }

    private func defaultSpawnMeshIndex() -> Int {
        guard let entity = entityID(from: store.state.selectedEntityID),
              let mesh = scene.scene.component(RenderMeshComponent.self, for: entity)
        else {
            return 0
        }
        return mesh.meshIndex
    }

    private func entityID(from rawID: UInt64?) -> EntityID? {
        guard let rawID else { return nil }
        return EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                        generation: UInt32(rawID >> 32))
    }

    // MARK: - MCP Bridge

    private func startMCPBridge() {
        mcpBridge.onCommand = { [weak self] action, params in
            guard let self else { return ["ok": false, "error": "editor unavailable"] }
            return self.handleMCPAction(action, params: params)
        }
        mcpBridge.start()
    }

    private func handleMCPAction(_ action: String, params: [String: Any]) -> [String: Any] {
        switch action {
        case "get_scene":
            return mcpGetScene()
        case "get_context_memory":
            return mcpGetContextMemory(params: params)
        case "get_ai_entity":
            return mcpGetAIEntity(params: params)
        case "get_selection":
            let ref = store.state.selectedEntityID.map { "scene:\($0)" }
            return ["ok": true, "selectedRef": ref as Any]
        case "find_entities":
            return mcpFindEntities(params: params)
        case "open_capability_session":
            return mcpOpenCapabilitySession(params: params)
        case "search_capabilities":
            return mcpSearchCapabilities(params: params)
        case "invoke_capability":
            return mcpInvokeCapability(params: params)
        case "submit_capability_plan":
            return mcpSubmitCapabilityPlan(params: params)
        case "close_capability_session":
            return mcpCloseCapabilitySession(params: params)
        default:
            return ["ok": false, "error": "unknown action '\(action)'"]
        }
    }

    private func mcpOpenCapabilitySession(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        let revision = scene.revision
        do {
            let activation = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.bootstrap(sessionID: sessionID,
                                                          sceneRevision: revision)
            }
            return mcpCapabilityActivationResponse(activation)
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpSearchCapabilities(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        do {
            let input = try mcpValidatedFrameworkInput(
                params,
                capabilityID: "system.search_capabilities"
            )
            let query = input["query"] as? String ?? ""
            let domain = input["domain"] as? String
            let access = (input["access"] as? String).flatMap(CapabilityAccess.init(rawValue:))
            let revision = scene.revision
            let activation = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.search(sessionID: sessionID,
                                                       query: query,
                                                       domain: domain,
                                                       access: access,
                                                       sceneRevision: revision)
            }
            return mcpCapabilityActivationResponse(activation)
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpCapabilityActivationResponse(
        _ activation: CapabilitySearchActivation
    ) -> [String: Any] {
        func encode(_ contracts: [CapabilityContract]) -> [[String: Any]] {
            contracts.map { contract in
                [
                    "id": contract.id,
                    "version": contract.version,
                    "tool_name": contract.toolName,
                    "title": contract.title,
                    "description": contract.description,
                    "domain": contract.domain,
                    "access": contract.access.rawValue,
                    "schema_hash": contract.schemaHash,
                    "input_schema": contract.inputSchema.jsonObject(),
                ]
            }
        }
        return [
            "ok": true,
            "snapshot_id": activation.snapshotID.uuidString,
            "active_tool_count": activation.activeToolCount,
            "capabilities": encode(activation.contracts),
            "active_capabilities": encode(activation.activeContracts),
        ]
    }

    private func mcpInvokeCapability(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        guard let toolName = params["tool_name"] as? String else {
            return ["ok": false, "error": "missing tool_name"]
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard JSONSerialization.isValidJSONObject(arguments),
              let input = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            return ["ok": false, "error": "arguments must be a JSON object"]
        }
        let revision = scene.revision
        do {
            let contract = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.contract(sessionID: sessionID,
                                                         toolName: toolName,
                                                         sceneRevision: revision)
            }
            if contract.access == .read {
                try JSONSchemaValidator.validate(data: input, against: contract.inputSchema)
                if let pluginID = contract.source.pluginID {
                    guard let executor = pluginCapabilityExecutor else {
                        throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
                    }
                    let querySnapshot = try makePluginQuerySnapshot(
                        pluginID: pluginID,
                        sceneRevision: revision
                    )
                    let payload = try executor.executeRead(
                        toolName: toolName,
                        input: input,
                        snapshot: try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                            try await mcpCapabilitySessions.snapshot(
                                sessionID: sessionID,
                                sceneRevision: revision
                            )
                        },
                        currentSceneRevision: revision,
                        querySnapshot: querySnapshot
                    )
                    let result = try JSONSerialization.jsonObject(with: payload,
                                                                  options: [.fragmentsAllowed])
                    return ["ok": true, "result": result]
                }
                switch contract.id {
                case "scene.get_entities":
                    return mcpGetScene()
                case "scene.get_selection":
                    let ref = store.state.selectedEntityID.map { "scene:\($0)" }
                    return ["ok": true, "selectedRef": ref as Any]
                case "scene.find_entities":
                    return mcpFindEntities(params: arguments)
                default:
                    return [
                        "ok": false,
                        "error": CapabilityExposureSessionError
                            .readCapabilityRequiresHostAdapter(contract.id).description,
                    ]
                }
            }

            let draft = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.createDraft(sessionID: sessionID,
                                                            toolName: toolName,
                                                            input: input,
                                                            sceneRevision: revision)
            }
            return [
                "ok": true,
                "status": "draft_created",
                "draft_id": draft.id.uuidString,
                "capability_id": draft.capabilityID,
                "capability_version": draft.capabilityVersion,
                "schema_hash": draft.schemaHash,
                "scene_revision": draft.sceneRevision,
            ]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpSubmitCapabilityPlan(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        do {
            let input = try mcpValidatedFrameworkInput(params,
                                                       capabilityID: "system.submit_plan")
            let summary = input["summary"] as? String ?? "AI capability plan"
            let reasoning = input["reasoning"] as? String
            guard let rawIDs = input["draft_ids"] as? [String],
                  rawIDs.count <= CapabilityDraftLimits.maximumDraftsPerPlan else {
                return [
                    "ok": false,
                    "error": "draft_ids may contain at most \(CapabilityDraftLimits.maximumDraftsPerPlan) ids",
                ]
            }
            let draftIDs = rawIDs.compactMap(UUID.init(uuidString:))
            guard draftIDs.count == rawIDs.count, Set(draftIDs).count == draftIDs.count else {
                return ["ok": false, "error": "draft_ids contains an invalid or duplicate id"]
            }
            let revision = scene.revision
            let validated = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.validatedDrafts(sessionID: sessionID,
                                                                ids: draftIDs,
                                                                sceneRevision: revision)
            }
            let builtInDrafts = validated.drafts.filter { $0.sourcePluginID == nil }
            let plan = try SceneCapabilityDraftLowering.plan(summary: summary,
                                                             reasoning: reasoning,
                                                             drafts: builtInDrafts)
            if validated.drafts.isEmpty {
                return [
                    "ok": true,
                    "status": "no_changes",
                    "summary": plan.summary,
                    "snapshot_id": validated.snapshot.id.uuidString,
                ]
            }
            // The executor prepares each operation against a shadow copy and
            // binds each record to the exact authority snapshot used above.
            let containsPluginDraft = validated.drafts.contains { $0.sourcePluginID != nil }
            let transaction: TransactionIR
            if containsPluginDraft {
                guard let executor = pluginCapabilityExecutor else {
                    throw EditorPluginCapabilityError.pluginNotEnabled(
                        validated.drafts.compactMap(\.sourcePluginID).first ?? "unknown"
                    )
                }
                transaction = try executor.buildTransaction(
                    summary: summary,
                    reasoning: reasoning,
                    drafts: validated.drafts,
                    snapshot: validated.snapshot,
                    scene: scene.scene,
                    currentSceneRevision: revision,
                    querySnapshots: try makePluginQuerySnapshots(
                        for: validated.drafts,
                        sceneRevision: revision
                    ),
                    approvalPolicy: .requiresApproval
                )
            } else {
                transaction = try SceneEditPlanExecutor().buildTransaction(
                    from: plan,
                    scene: scene.scene,
                    baseSceneRevision: revision,
                    approvalPolicy: .requiresApproval,
                    exposureSnapshot: validated.snapshot
                )
            }
            let result = try runPlanTransaction(
                transaction,
                capabilityContext: makeCapabilityInvocationContext(defaultSource: .system)
            )
            try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.consume(sessionID: sessionID, ids: draftIDs)
            }
            return [
                "ok": true,
                "summary": plan.summary,
                "transaction_id": result.transactionID,
                "disposition": result.disposition.rawValue,
                "snapshot_id": validated.snapshot.id.uuidString,
            ]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpValidatedFrameworkInput(
        _ params: [String: Any],
        capabilityID: String
    ) throws -> [String: Any] {
        guard let contract = CapabilityRegistry.aiDefault.descriptor(for: capabilityID)?.contract else {
            throw CapabilityDraftError.unknownTool(capabilityID)
        }
        var input = params
        input.removeValue(forKey: "action")
        input.removeValue(forKey: "session_id")
        guard JSONSerialization.isValidJSONObject(input) else {
            throw CapabilityDraftError.invalidInput("input must be a JSON object")
        }
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        try JSONSchemaValidator.validate(data: data, against: contract.inputSchema)
        return input
    }

    private func mcpCloseCapabilitySession(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        do {
            try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.removeSession(sessionID)
            }
            return ["ok": true]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpGetScene() -> [String: Any] {
        let snapshot = SceneSemanticEncoder().encode(
            scene.scene,
            selectedEntityID: store.state.selectedEntityID,
            workspaceMode: store.state.workspaceMode.rawValue,
            localeIdentifier: nil
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(snapshot),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return ["ok": false, "error": "scene encoding failed"] }
        return ["ok": true, "scene": json]
    }

    private func mcpFindEntities(params: [String: Any]) -> [String: Any] {
        let nameQuery = (params["name"] as? String)?.lowercased()
        let kindFilter = params["kind"] as? String
        let componentFilter = (params["component"] as? String)?.lowercased()
        let limit = max(1, min((params["limit"] as? Int) ?? 20, 200))
        let nearValues = (params["near_position"] as? [Any])?.compactMap {
            ($0 as? NSNumber)?.doubleValue
        }
        let nearPosition: [Double]? = nearValues?.count == 3 ? nearValues : nil
        let nearRadius = (params["near_radius"] as? NSNumber)?.doubleValue

        let snapshot = SceneSemanticEncoder().encode(
            scene.scene,
            selectedEntityID: store.state.selectedEntityID,
            workspaceMode: store.state.workspaceMode.rawValue,
            localeIdentifier: nil
        )
        var matches: [(entity: SceneSemanticSnapshot.Entity, distance: Double?)] = []
        for entity in snapshot.entities {
            if let nq = nameQuery, !entity.name.lowercased().contains(nq) { continue }
            if let kf = kindFilter, entity.kind != kf { continue }
            if let componentFilter,
               !entity.components.contains(where: { $0.lowercased() == componentFilter }) {
                continue
            }
            var distance: Double?
            if let center = nearPosition, let radius = nearRadius {
                guard let position = entity.worldPosition ?? entity.position,
                      position.count == 3 else { continue }
                let dx = Double(position[0]) - center[0]
                let dy = Double(position[1]) - center[1]
                let dz = Double(position[2]) - center[2]
                let value = (dx * dx + dy * dy + dz * dz).squareRoot()
                guard value <= radius else { continue }
                distance = value
            }
            matches.append((entity, distance))
        }
        if nearPosition != nil {
            matches.sort { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
        }
        let results: [[String: Any]] = matches.prefix(limit).map { match in
            var result: [String: Any] = [
                "id": match.entity.id,
                "name": match.entity.name,
                "kind": match.entity.kind,
                "components": match.entity.components,
            ]
            if let position = match.entity.worldPosition ?? match.entity.position {
                result["position"] = position
            }
            if let distance = match.distance { result["distance"] = distance }
            return result
        }
        return ["ok": true, "count": results.count, "entities": results]
    }

    private func mcpGetContextMemory(params: [String: Any]) -> [String: Any] {
        guard let store = contextMemoryStore else {
            return ["ok": false, "error": "context memory is not configured for this project"]
        }
        let budget = params["budget"] as? Int ?? 20
        let semaphore = DispatchSemaphore(value: 0)
        final class State: @unchecked Sendable { var view: [[String: String]] = [] }
        let state = State()
        Task {
            state.view = await store.symbolicView(budget: budget)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 3) == .success else {
            return ["ok": false, "error": "context memory read timed out"]
        }
        return ["ok": true, "entries": state.view, "count": state.view.count]
    }

    private func mcpGetAIEntity(params: [String: Any]) -> [String: Any] {
        let targetRef = (params["entity_id"] as? String) ?? store.state.selectedEntityID.map { "scene:\($0)" }
        guard let targetRef, !targetRef.isEmpty else {
            return ["ok": false, "error": "missing target entity; pass entity_id or select an entity"]
        }
        guard let record = readAIWorldEntityRecord(ref: targetRef) else {
            return ["ok": false, "error": "no AI world record for '\(targetRef)'"]
        }
        return [
            "ok": true,
            "targetRef": targetRef,
            "entity": jsonObject(record) ?? [:],
        ]
    }

    private func observeWorldEvents(_ events: [WorldEvent]) {
        guard !events.isEmpty else { return }
        let worldContext = self.aiWorldContext
        let session = session
        let previousTask = pendingWorldObservationTask
        pendingWorldObservationTask = Task {
            await previousTask?.value
            await worldContext.observe(events: events)
            if let session {
                await session.observe(events: events)
            }
        }
    }

    private func readAIWorldEntityRecord(ref: String) -> WorldEntityRecord? {
        let semaphore = DispatchSemaphore(value: 0)
        let worldContext = self.aiWorldContext
        final class ReadState: @unchecked Sendable {
            var record: WorldEntityRecord?
        }
        let state = ReadState()
        Task {
            state.record = await worldContext.entityRecord(ref: ref)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else { return nil }
        return state.record
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Accumulates raw delta time and dispatches `EditorFrameStats` when the
    /// diagnostics averaging window is full. Combines:
    ///   - PhaseTimings from EngineHost (input / simulation / renderPrepare / renderSubmit)
    ///   - GPU present time from the render completion handler
    ///   - RenderFrameStats from the GPU backend (draw calls, passes, etc.)
    private func recordAndDispatchFrameStats(deltaTime: Double,
                                              simulationDelta: Double) -> Bool {
        guard deltaTime.isFinite, deltaTime > 0 else { return false }
        frameTimingAccumulator += deltaTime
        frameTimingCount += 1
        guard frameTimingAccumulator >= Self.frameStatsDispatchInterval else { return false }

        let phaseTimings = engine.lastTimings
        let renderStats = lastRenderFrameStats

        let frameSeconds = frameTimingAccumulator / Double(frameTimingCount)

        let stats = EditorFrameStats(
            frameSeconds: frameSeconds,
            inputSeconds: phaseTimings.inputSeconds,
            simulationSeconds: phaseTimings.simulationSeconds,
            renderPrepareSeconds: phaseTimings.renderPrepareSeconds,
            renderSubmitSeconds: phaseTimings.renderSubmitSeconds,
            gpuPresentSeconds: lastRenderSubmitSeconds,
            drawCallCount: renderStats.drawCallCount,
            passCount: renderStats.passCount,
            renderBundleCount: renderStats.renderBundleCount,
            shadowedLightCount: renderStats.shadowedLightCount,
            shadowCascadeCount: renderStats.shadowCascadeCount,
            shadowMapResolution: renderStats.shadowMapResolution,
            cpuSkyboxEncodeNS: renderStats.cpuSkyboxEncodeNS,
            cpuBaseEncodeNS: renderStats.cpuBaseEncodeNS,
            cpuPostProcessEncodeNS: renderStats.cpuPostProcessEncodeNS
        )

        store.dispatch(.updateFrameStats(stats))

        // Reset the averaging window.
        frameTimingAccumulator = 0
        frameTimingCount = 0
        return true
    }
}
