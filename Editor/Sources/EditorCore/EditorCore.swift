import AIRuntime
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

/// 缂栬緫鍣ㄥ簲鐢ㄥ煙锛氭妸 `EngineHost`銆乣EditorStore` 涓?`InputState` 姹囨€绘垚涓€涓璞°€?
///
/// 涓?GuavaUIApp 閰嶅悎浣跨敤锛?
///   1. 鍚姩鏃剁敱璋冪敤鏂瑰疄渚嬪寲 `EditorApplication`锛?
///   2. 鍦?`AppRuntime.run` 鐨?`onTick` 鍥炶皟閲岃皟鐢?`tick(deltaTime:)` 鎺ㄨ繘寮曟搸锛?
///   3. 閫€鍑轰富寰幆鍚庤皟鐢?`shutdown()` 娓呯悊寮曟搸璧勬簮銆?
///
/// 鑷韩涓嶆寔鏈夌獥鍙?/ wgpu surface 鈥?UI 娓叉煋鐢?GuavaUIApp 鎺ョ锛屽紩鎿庝粎璐熻矗
/// 浠跨湡涓庯紙鏈潵鐨勶級绂诲睆娓叉煋銆?
public final class EditorApplication: @unchecked Sendable {
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
    private var pendingViewportEvents: [InputEvent] = []
    private var _viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)
    private var lastViewportSurfaceState = ViewportSurfaceState()
    private var openSettingsWindowHandler: (() -> Void)?
    private var displayInvalidationHandler: (() -> Void)?
    private var vsyncModeHandler: ((EditorVSyncMode) -> Void)?
    private var session: Session?
    private var pendingSessionProposal: Proposal?
    private var pendingAssistantMessageID: String?
    private let mcpBridge = MCPBridge()
    private let editLog: EditLog
    private var physicsPlaySnapshot: SceneRuntime?
    private var frameTimingAccumulator: Double = 0
    private var frameTimingCount: Int = 0
    private var frameTiming = EditorFrameTiming()

    public init(projectDirectory: String,
                backendConfig: WGPUDeviceConfig? = nil,
                backend: WGPUBackend? = nil,
                events: PlatformEventBridge = PlatformEventBridge(),
                initialAISettings: EditorAISettings = .default,
                initialCapabilitySettings: EditorCapabilitySettings = .default) throws {
        let resolvedBackendConfig = backendConfig ?? .init()
        let resolvedBackend = backend ?? WGPUBackend(config: resolvedBackendConfig)
        _ = try EditorAssetCatalog.loadProject(at: projectDirectory)
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
        self.session = initialSession
        self.perceptionService = ps
        #if canImport(Vision)
        Task { await ps.register(AppleVisionPerceptionWorker()) }
        #endif

        scene.onRevisionChanged = { revision in
            store.dispatch(.setSceneRevision(revision))
        }
        store.dispatch(.setSceneRevision(scene.revision))
        if let selection = initialSelectedEntityID {
            store.dispatch(.setSelectedEntity(selection))
        }

        startMCPBridge()
    }

    public func bootstrap() {
        eventToken = events.subscribe { [weak self] event in
            self?.handlePlatformEvent(event)
        }
        engine.start(renderSurface: nil, enableViewportSurface: true)
        // 榛樿鍚敤绂诲睆娓叉煋锛岃寮曟搸娓叉煋鍒颁竴涓?viewport 绾圭悊浜ょ粰缂栬緫鍣ㄦ樉绀恒€?
        // 涓嶅紑鍚?viewportResolve 鏃?UI 浼氫竴鐩村仠鍦?"Waiting for first render packet"銆?
        engine.queueRenderSettings(makeViewportRenderSettings(shadowsEnabled: store.state.viewportShadowsEnabled))
        store.dispatch(.setConnected(true))
        logConsole("Editor connected to runtime")
    }

    public func tick(deltaTime: Double) {
        let didUpdateFrameTiming = recordFrameTiming(deltaTime)
        store.dispatch(.tickFrame(store.state.frameIndex &+ 1))
        let inputEvents = pendingViewportEvents
        pendingViewportEvents.removeAll(keepingCapacity: true)
        inputState.process(inputEvents)
        scene.tickScene(deltaTime: deltaTime)
        engine.tick(
            deltaTime: deltaTime,
            inputEvents: inputEvents,
            drawableSize: _viewportDrawableSize,
            shouldRender: store.state.shouldRender,
            renderSceneOverride: scene.currentRenderScene(),
            jointPaletteOverride: scene.currentJointPaletteMap()
        )

        let surface = engine.currentViewportSurfaceState()
        if surface != lastViewportSurfaceState {
            lastViewportSurfaceState = surface
            store.dispatch(.viewportSurfaceUpdated)
        }
        if didUpdateFrameTiming {
            store.dispatch(.frameTimingUpdated)
        }
    }

    public func shutdown() {
        logConsole("Editor runtime shutdown")
        if let eventToken {
            events.unsubscribe(eventToken)
            self.eventToken = nil
        }
        engine.shutdown()
    }

    public func enqueueViewportInput(_ event: InputEvent) {
        pendingViewportEvents.append(event)
    }

    public var viewportDrawableSize: RenderDrawableSize { _viewportDrawableSize }

    public func setViewportDrawableSize(_ size: RenderDrawableSize) {
        guard _viewportDrawableSize != size else { return }
        _viewportDrawableSize = size
    }

    public func setViewportRenderCompletionHandler(_ handler: (@Sendable (ViewportSurfaceState) -> Void)?) {
        engine.setRenderCompletionHandler { completion in
            handler?(completion.viewportSurfaceState)
        }
    }

    public func setOpenSettingsWindowHandler(_ handler: (() -> Void)?) {
        openSettingsWindowHandler = handler
    }

    public func openSettingsWindow() {
        openSettingsWindowHandler?()
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

    /// 鎶婅祫浜х敓鎴愬埌鍦烘櫙涓紝骞舵妸鏂板疄浣撹涓哄綋鍓嶉€変腑銆?
    @discardableResult
    public func spawnAsset(_ asset: EditorAsset, at position: SIMD3<Float> = .zero) -> UInt64? {
        guard let id = scene.spawnEntity(from: asset, at: position) else {
            logConsole("Failed to spawn \(asset.name)", severity: .error)
            return nil
        }
        store.dispatch(.setSelectedEntity(id))
        logConsole("Spawned \(asset.name)", detail: "entity \(id)")
        return id
    }

    /// Runs visual perception on `imageURL` and injects the resulting inferred properties
    /// into the World and the active Session for the given entity.
    /// Call this from the UI or MCP after the user selects a reference image for an entity.
    public func tagEntity(_ entityRef: String, imageURL: URL) {
        let ps = perceptionService
        Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await ps.tag(entityRef: entityRef, imageURL: imageURL)
                self.observeWorldEvents(events)
                self.logConsole("Tagged \(entityRef)",
                                detail: "\(events.count) inferred properties")
            } catch {
                self.logConsole("Perception unavailable for \(entityRef)",
                                severity: .warning,
                                detail: error.localizedDescription)
            }
        }
    }

    /// 澶勭悊 AssetBrowser 鍦ㄨ鍙ｅ唴鏀句笅璧勪骇鐨勪簨浠躲€傚鏋滃綋鍓嶅厜鏍囧潗鏍?
    /// 钀藉湪瑙嗗彛鐭╁舰鍐呭垯鐢熸垚瀹炰綋锛屽惁鍒欏彧鏄竻鎺夋嫋鍔ㄧ姸鎬併€?
    @discardableResult
    public func handleAssetDrop(at cursorX: Float, cursorY: Float) -> Bool {
        guard let payload = store.state.activeAssetDrag else { return false }
        defer { store.dispatch(.endAssetDrag) }
        let dropPayload = AssetDropPayload(id: payload.assetID,
                                           name: payload.displayName,
                                           kind: payload.kindLabel)
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
        guard let asset = EditorAssetCatalog.asset(for: payload.assetID) else {
            logConsole("Missing asset for drop", severity: .error, detail: payload.assetID)
            return false
        }
        let position = dropWorldPosition(cursorX: cursorX, cursorY: cursorY, frame: frame)
        spawnAsset(asset, at: position)
        return true
    }

    /// 鎶婅鍙ｅ唴鍏夋爣鍧愭爣鎶曞埌涓栫晫 y=0 骞抽潰锛屼綔涓鸿祫浜ц惤鐐广€?
    /// 鎽勫儚鏈烘寚鍚戜笂鏂规垨涓庡钩闈㈠钩琛屾椂閫€鍖栦负 (0,0,0)銆?
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

        // 涓?y = 0 骞抽潰鐩镐氦銆傛憚鍍忔満鍦ㄥ钩闈笅鏂规垨瑙嗙嚎鎸囧悜涓婃柟鏃堕€€鍖栥€?
        if abs(dir.y) < 1e-4 { return .zero }
        let t = -camera.eye.y / dir.y
        if t <= 0 || t > 1_000 { return .zero }
        var hit = camera.eye + dir * t
        hit.y = 0
        return hit
    }

    public func queueViewportRenderSettings(_ settings: RenderSettings) {
        engine.queueRenderSettings(settings)
    }

    public func setViewportShadowsEnabled(_ enabled: Bool) {
        if store.state.viewportShadowsEnabled != enabled {
            store.dispatch(.setViewportShadowsEnabled(enabled))
        }
        engine.queueRenderSettings(makeViewportRenderSettings(shadowsEnabled: enabled))
        logConsole(enabled ? "Viewport shadows enabled" : "Viewport shadows disabled")
    }

    /// Transitions to a new playback state.
    /// - On `.playing`: snapshots the current scene, enables Jolt physics simulation.
    /// - On `.paused`: freezes physics (mode 鈫?off) without restoring the scene.
    /// - On `.stopped`: restores the pre-play scene snapshot and disables physics.
    public func applyPlaybackState(_ next: PlaybackState) {
        let current = store.state.playbackState
        guard current != next else { return }

        switch next {
        case .playing:
            if physicsPlaySnapshot == nil {
                physicsPlaySnapshot = scene.scene
                persistPhysicsPlaySnapshot()
            }
            var settings = scene.scene.physicsSettings
            settings.simulationMode = .play
            settings.backendKind = .jolt
            scene.scene.setPhysicsSettings(settings)
            store.dispatch(.setPlaybackState(.playing))
            logConsole("Physics simulation started")

        case .paused:
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
            if let snapshot = physicsPlaySnapshot {
                scene.scene = snapshot
                scene.notifyRevisionChanged()
                physicsPlaySnapshot = nil
                store.dispatch(.setSceneRevision(scene.revision))
            }
            deletePersistedPhysicsPlaySnapshot()
            var settings = scene.scene.physicsSettings
            settings.simulationMode = .off
            settings.backendKind = .none
            scene.scene.setPhysicsSettings(settings)
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
            var tmpAdapter = EditorSceneAdapter()
            tmpAdapter.scene = snapshot
            let manifest = tmpAdapter.manifest()
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
            var tmpAdapter = EditorSceneAdapter()
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

    private func makeViewportRenderSettings(shadowsEnabled: Bool) -> RenderSettings {
        RenderSettings(
            stage: .r4LightingPBRShadow,
            shadowSettings: RenderShadowSettings(enabled: shadowsEnabled),
            enableOffscreenViewport: true
        )
    }

    public func resetPreviewScene() {
        scene.resetToPreviewScene()
        if let selection = scene.defaultSelectionID {
            store.dispatch(.setSelectedEntity(selection))
        } else {
            store.dispatch(.setSelectedEntity(nil))
        }
        logConsole("Created new preview scene")
    }

    @discardableResult
    public func saveSceneManifest() -> URL? {
        do {
            let guavaDirectory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
                .appendingPathComponent(".guava", isDirectory: true)
            try FileManager.default.createDirectory(at: guavaDirectory,
                                                    withIntermediateDirectories: true)
            let url = guavaDirectory.appendingPathComponent("editor-scene-manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(scene.manifest(selectedEntityID: store.state.selectedEntityID))
            try data.write(to: url, options: [.atomic])
            logConsole("Saved scene manifest", detail: url.path)
            return url
        } catch {
            logConsole("Failed to save scene manifest",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    public func openSceneManifest() -> EditorSceneManifest? {
        let url = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("editor-scene-manifest.json")
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let result = scene.load(manifest: manifest)
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            logConsole("Opened scene manifest",
                       detail: "\(result.entityCount) entities restored from revision \(manifest.revision)")
            return manifest
        } catch CocoaError.fileReadNoSuchFile {
            logConsole("No saved scene manifest",
                       severity: .warning,
                       detail: url.path)
            return nil
        } catch {
            logConsole("Failed to open scene manifest",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    @discardableResult
    public func reloadAssets() -> Int {
        do {
            let assets = try EditorAssetCatalog.loadProject(at: projectDirectory)
            logConsole("Reloaded assets", detail: "\(assets.count) importable files")
            return assets.count
        } catch {
            logConsole("Failed to reload assets",
                       severity: .error,
                       detail: String(describing: error))
            return 0
        }
    }

    public func currentRenderStats() -> RenderFrameStats {
        engine.currentRenderStats()
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        engine.currentViewportSurfaceState()
    }

    public func currentFrameTiming() -> EditorFrameTiming {
        frameTiming
    }

    public func currentSelectedEntityTranslation() -> SIMD3<Float>? {
        guard let entity = entityID(from: store.state.selectedEntityID) else {
            return nil
        }
        return scene.scene.localTransform(for: entity)?.translation
    }

    /// Session-era stub: returns empty — Session handles NL inference.
    public func localIntentSuggestions(
        for text: String,
        maxCount: Int = 3
    ) -> [(verbID: String, summary: String, confidence: Double)] { [] }

    public func submitNaturalLanguageIntent(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if store.state.pendingConfirmationRequest != nil {
            store.dispatch(.setAIStatusMessage("Resolve the pending confirmation before submitting another AI action."))
            return
        }

        if let session {
            submitNaturalLanguageIntentWithSession(text, session: session)
            return
        }

        store.dispatch(.setAIStatusMessage("No AI provider configured."))
    }

    private func submitNaturalLanguageIntentWithSession(_ text: String, session: Session) {
        let locale = store.state.language.lprojName
        let t0 = Date()
        store.dispatch(.setAIStatusMessage("Planning..."))
        store.dispatch(.appendChatMessage(AIChatMessage(role: .user, text: text)))
        let assistantID = UUID().uuidString
        pendingAssistantMessageID = assistantID
        store.dispatch(.appendChatMessage(AIChatMessage(id: assistantID,
                                                        role: .assistant,
                                                        text: "",
                                                        assistantState: .thinking)))

        let capturedAid = assistantID
        let progressHandler: @Sendable (String) -> Void = { [weak self] partial in
            Task { @MainActor [weak self] in
                self?.store.dispatch(.updateChatMessage(id: capturedAid,
                                                        assistantState: .streaming(partial)))
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let proposal = try await session.process(
                    .naturalLanguage(text: text, locale: locale ?? "en"),
                    onProgress: progressHandler
                )
                let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)

                guard !proposal.plan.isEmpty else {
                    self.store.dispatch(.setAIStatusMessage("No scene changes."))
                    if let aid = self.pendingAssistantMessageID {
                        let reply = proposal.plan.summary.isEmpty ? "No scene changes needed." : proposal.plan.summary
                        self.store.dispatch(.updateChatMessage(id: aid,
                                                               assistantState: .replied(reply)))
                        self.pendingAssistantMessageID = nil
                    }
                    Task { await session.recordOutcome(toolUseID: proposal.toolUseID,
                                                       content: "Acknowledged.",
                                                       proposalID: proposal.id) }
                    return
                }

                let transaction = try SceneEditPlanExecutor().buildTransaction(
                    from: proposal.plan,
                    scene: self.scene.scene,
                    baseSceneRevision: proposal.baseSceneRevision,
                    approvalPolicy: proposal.approvalPolicy
                )
                self.logConsole("AI inference: \(latencyMs)ms", detail: proposal.plan.summary)
                self.pendingSessionProposal = proposal
                self.submitPlanTransaction(
                    transaction,
                    capabilityContext: self.makeCapabilityInvocationContext(
                        defaultSource: .ai,
                        defaultConfidence: proposal.confidence
                    )
                )
            } catch {
                let message = error.localizedDescription
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
                                       capabilityContext: CapabilityInvocationContext? = nil) {
        if store.state.pendingConfirmationRequest != nil {
            store.dispatch(.setAIStatusMessage("Resolve the pending confirmation before submitting another AI action."))
            return
        }
        do {
            _ = try runPlanTransaction(transaction, capabilityContext: capabilityContext)
        } catch {
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings([]))
            store.dispatch(.setAIStatusMessage(error.localizedDescription))
        }
    }

    @discardableResult
    private func runPlanTransaction(_ transaction: TransactionIR,
                                    capabilityContext: CapabilityInvocationContext? = nil) throws -> CapabilityInvocationResult {
        var context = makeExecutionContext()
        let result = try intentCoordinator.submitPlan(transaction,
                                                      executionContext: &context,
                                                      capabilityContext: capabilityContext)
        applyInvocationResult(result, executionContext: &context)
        return result
    }

    public func dismissUnresolvedIntent(id: String) {}

    // MARK: - Undo / Redo

    public var canUndo: Bool { intentCoordinator.undoStack.canUndo }
    public var canRedo: Bool { intentCoordinator.undoStack.canRedo }

    public func undo() {
        var context = makeExecutionContext()
        guard intentCoordinator.undo(executionContext: &context) else { return }
        if let updatedScene = context.sceneRuntime {
            scene.scene = updatedScene
            scene.notifyRevisionChanged()
        }
        store.dispatch(.setAIStatusMessage("Undone"))
        logConsole("Undo applied", severity: .info)
    }

    public func redo() {
        var context = makeExecutionContext()
        guard intentCoordinator.redo(executionContext: &context) else { return }
        if let updatedScene = context.sceneRuntime {
            scene.scene = updatedScene
            scene.notifyRevisionChanged()
        }
        store.dispatch(.setAIStatusMessage("Redone"))
        logConsole("Redo applied", severity: .info)
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

    public func resolvePendingConfirmation(pickedOptionID: String) {
        guard let request = store.state.pendingConfirmationRequest,
              let question = request.questions.first
        else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }

        let outcome: ConfirmationAnswerOutcome = pickedOptionID == "skip" ? .skipped : .accepted
        let resolution = ConfirmationResolution(batchID: request.batchID,
                                                correlationID: request.correlationID,
                                                answers: [
                                                    ConfirmationAnswer(questionID: question.id,
                                                                       outcome: outcome,
                                                                       pickedOptionID: pickedOptionID)
                                                ],
                                                userID: "local-editor",
                                                partial: false)
        var context = makeExecutionContext()
        do {
            let result = try intentCoordinator.resolvePlanConfirmation(resolution,
                                                                       executionContext: &context)
            applyInvocationResult(result, executionContext: &context)
        } catch {
            store.dispatch(.setAIStatusMessage(error.localizedDescription))
        }
    }

    public func acceptPendingConfirmation() {
        resolvePendingConfirmation(pickedOptionID: "confirm")
    }

    public func skipPendingConfirmation() {
        resolvePendingConfirmation(pickedOptionID: "skip")
    }

    private func handlePlatformEvent(_ event: InputEvent) {
        switch event {
        case let .mouseButtonDown(button):
            if EditorViewportInputController.shared.hasActivePointerSession,
               EditorViewportDropTarget.frame?.contains(x: button.x, y: button.y) != true {
                EditorGizmoController.shared.clearDrag()
                EditorViewportInputController.shared.endPointerSession()
            }
        case let .mouseButtonUp(button):
            if EditorViewportInputController.shared.hasActivePointerSession,
               EditorViewportDropTarget.frame?.contains(x: button.x, y: button.y) != true {
                EditorGizmoController.shared.clearDrag()
                EditorViewportInputController.shared.endPointerSession()
            }
        case .windowFocusGained:
            store.dispatch(.setWindowFocused(true))
        case .windowFocusLost:
            store.dispatch(.setWindowFocused(false))
            EditorGizmoController.shared.clearDrag()
            EditorViewportInputController.shared.reset()
        case .windowMinimized:
            store.dispatch(.setWindowMinimized(true))
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
    public func applyAISettings(_ settings: EditorAISettings, apiKey: String) {
        AIKeychain.save(key: apiKey, provider: settings.provider)
        store.dispatch(.setAISettings(settings))
        store.dispatch(.clearChatHistory)
        pendingAssistantMessageID = nil
        let newSession = Self.makeSession(for: settings)
        if let newSession {
            let worldContext = self.aiWorldContext
            Task {
                await newSession.replaceWorldView(await worldContext.snapshot())
            }
        }
        session = newSession
    }

    public func applyCapabilitySettings(_ settings: EditorCapabilitySettings) {
        store.dispatch(.setCapabilitySettings(settings))
        intentCoordinator.configureCapabilityPlanner(Self.makeCapabilityInvocationPlanner(for: settings))
    }

    /// Removes the stored API key for the current provider and disables AI.
    public func clearAIKey() {
        AIKeychain.delete(provider: store.state.aiSettings.provider)
        session = nil
        store.dispatch(.clearChatHistory)
        pendingAssistantMessageID = nil
        var settings = store.state.aiSettings
        settings.provider = .none
        store.dispatch(.setAISettings(settings))
    }

    /// Returns `true` if a non-empty API key is stored for the current provider.
    public func hasStoredAIKey() -> Bool {
        AIKeychain.hasKey(for: store.state.aiSettings.provider)
    }

    static func makeSession(for settings: EditorAISettings,
                            initialWorldView: WorldView = WorldView()) -> Session? {
        switch settings.provider {
        case .none:
            return nil
        case .anthropic:
            guard let key = AIKeychain.load(provider: .anthropic) else { return nil }
            return Session(config: .anthropic(apiKey: key, model: settings.model,
                                              autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView)
        case .openai:
            guard let key = AIKeychain.load(provider: .openai) else { return nil }
            return Session(config: .openAI(apiKey: key, model: settings.model,
                                           autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView)
        case .deepseek:
            guard let key = AIKeychain.load(provider: .deepseek) else { return nil }
            return Session(config: .deepSeek(apiKey: key, model: settings.model,
                                             autoApprove: settings.autoApprove),
                           initialWorldView: initialWorldView)
        }
    }

    static func makeCapabilityInvocationPlanner(for settings: EditorCapabilitySettings) -> CapabilityInvocationPlanner {
        CapabilityInvocationPlanner(gate: ReleasePhaseGate(activePhase: settings.releasePhase.runtimePhase))
    }

    private func submitResolvedIntent(_ intent: IntentIR) {
        do {
            let transaction = try intentTransactionBuilder.buildTransaction(from: intent,
                                                                            context: makeIntentTransactionBuildContext())
            submitPlanTransaction(
                transaction,
                capabilityContext: makeCapabilityInvocationContext(
                    defaultSource: intent.source,
                    defaultConfidence: intent.confidence,
                    defaultEvidence: intent.evidence
                )
            )
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
                                    isSceneEditable: store.state.playbackState != .playing,
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
                editLog.append(edit)
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
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings(result.warnings))
            store.dispatch(.setAIStatusMessage("Discarded \(result.transactionID)"))
            if let aid = pendingAssistantMessageID {
                store.dispatch(.updateChatMessage(id: aid, assistantState: .discarded))
                pendingAssistantMessageID = nil
            }
            if let proposal = pendingSessionProposal {
                let stepCount = proposal.plan.steps.count
                let rejected = (0..<stepCount).map { "step_\($0)" }
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
        case "execute_plan":
            return mcpExecutePlan(params: params)
        case "analyze_image":
            return mcpAnalyzeImage(params: params)
        case "get_ai_entity":
            return mcpGetAIEntity(params: params)
        case "get_selection":
            let ref = store.state.selectedEntityID.map { "scene:\($0)" }
            return ["ok": true, "selectedRef": ref as Any]
        case "set_playback_state":
            return mcpSetPlaybackState(params: params)
        default:
            return ["ok": false, "error": "unknown action '\(action)'"]
        }
    }

    private func mcpSetPlaybackState(params: [String: Any]) -> [String: Any] {
        guard let stateStr = params["state"] as? String else {
            return ["ok": false, "error": "missing 'state' field (playing|paused|stopped)"]
        }
        guard let next = PlaybackState(rawValue: stateStr) else {
            return ["ok": false, "error": "unknown state '\(stateStr)' — expected 'playing', 'paused', or 'stopped'"]
        }
        applyPlaybackState(next)
        return ["ok": true, "state": next.rawValue]
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

    private func mcpAnalyzeImage(params: [String: Any]) -> [String: Any] {
        guard let imagePath = params["image_path"] as? String, !imagePath.isEmpty else {
            return ["ok": false, "error": "missing 'image_path' field"]
        }
        let maxResults = max(1, min((params["max_results"] as? Int) ?? 5, 20))
        let targetRef = (params["entity_id"] as? String) ?? store.state.selectedEntityID.map { "scene:\($0)" }
        guard let targetRef, !targetRef.isEmpty else {
            return ["ok": false, "error": "missing target entity; pass entity_id or select an entity"]
        }
        guard let targetRawID = rawEntityID(fromSceneRef: targetRef),
              let targetEntity = entityID(from: targetRawID),
              scene.scene.contains(targetEntity)
        else {
            return ["ok": false, "error": "invalid target entity '\(targetRef)'"]
        }

        let ps = perceptionService
        let semaphore = DispatchSemaphore(value: 0)
        final class MCPState: @unchecked Sendable {
            var result: [String: Any] = [:]
        }
        let state = MCPState()
        Task {
            do {
                let events = try await ps.tag(entityRef: targetRef,
                                              imageURL: URL(fileURLWithPath: imagePath),
                                              maxResults: maxResults)
                let applicationResult = self.applyWorldEventsSynchronously(events)
                self.store.dispatch(.setAIStatusMessage(
                    applicationResult.localApplied
                        ? "Perception updated \(targetRef)"
                        : "Perception ran; no AI world update was applied"
                ))
                state.result = [
                    "ok": true,
                    "targetRef": targetRef,
                    "worldApplied": applicationResult.localApplied,
                    "sessionApplied": applicationResult.sessionApplied,
                    "events": events.count,
                ]
            } catch {
                state.result = ["ok": false, "error": error.localizedDescription]
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            return ["ok": false, "error": "perception timed out"]
        }
        return state.result
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
        Task {
            await worldContext.observe(events: events)
            if let session {
                await session.observe(events: events)
            }
        }
    }

    private func applyWorldEventsSynchronously(_ events: [WorldEvent]) -> (localApplied: Bool, sessionApplied: Bool) {
        guard !events.isEmpty else { return (false, false) }
        let semaphore = DispatchSemaphore(value: 0)
        let worldContext = self.aiWorldContext
        let session = session
        final class ApplyState: @unchecked Sendable {
            var localApplied = false
            var sessionApplied = false
        }
        let state = ApplyState()
        Task {
            await worldContext.observe(events: events)
            state.localApplied = true
            if let session {
                await session.observe(events: events)
                state.sessionApplied = true
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            return (false, false)
        }
        return (state.localApplied, state.sessionApplied)
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

    private func rawEntityID(fromSceneRef ref: String) -> UInt64? {
        guard ref.hasPrefix("scene:") else { return nil }
        return UInt64(ref.dropFirst("scene:".count))
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func mcpExecutePlan(params: [String: Any]) -> [String: Any] {
        guard let planDict = params["plan"] as? [String: Any],
              let planData = try? JSONSerialization.data(withJSONObject: planDict),
              let plan = try? JSONDecoder().decode(SceneEditPlan.self, from: planData)
        else { return ["ok": false, "error": "invalid plan"] }
        do {
            let transaction = try SceneEditPlanExecutor().buildTransaction(
                from: plan,
                scene: scene.scene,
                baseSceneRevision: nil,
                approvalPolicy: .automatic
            )
            let result = try runPlanTransaction(
                transaction,
                capabilityContext: makeCapabilityInvocationContext(defaultSource: .system)
            )
            return [
                "ok": true,
                "summary": plan.summary,
                "disposition": result.disposition.rawValue,
            ]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func recordFrameTiming(_ deltaTime: Double) -> Bool {
        guard deltaTime.isFinite, deltaTime > 0 else { return false }
        frameTimingAccumulator += deltaTime
        frameTimingCount += 1
        guard frameTimingAccumulator >= 0.25 else { return false }

        let fps = Double(frameTimingCount) / frameTimingAccumulator
        let frameMs = (frameTimingAccumulator / Double(frameTimingCount)) * 1_000
        frameTiming = EditorFrameTiming(framesPerSecond: fps, frameMilliseconds: frameMs)
        frameTimingAccumulator = 0
        frameTimingCount = 0
        return true
    }
}

public struct EditorFrameTiming: Sendable, Equatable {
    public var framesPerSecond: Double
    public var frameMilliseconds: Double

    public init(framesPerSecond: Double = 0,
                frameMilliseconds: Double = 0) {
        self.framesPerSecond = framesPerSecond
        self.frameMilliseconds = frameMilliseconds
    }
}
