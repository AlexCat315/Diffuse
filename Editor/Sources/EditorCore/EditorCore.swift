import AIRuntime
import AssetPipeline
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import simd

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
    public let engine: EngineHost
    public let projectDirectory: String
    public let store: EditorStore
    public let inputState: InputState
    public let scene: EditorSceneAdapter

    private let observationBus: ObservationBus
    private let intentCoordinator: IntentRuntimeCoordinator
    private let intentTransactionBuilder = IntentTransactionBuilder()
    private let events: PlatformEventBridge
    private var eventToken: PlatformEventBridge.SubscriptionToken?
    private var pendingViewportEvents: [InputEvent] = []
    private var viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)
    private var lastViewportSurfaceState = ViewportSurfaceState()
    private var openSettingsWindowHandler: (() -> Void)?
    private var displayInvalidationHandler: (() -> Void)?
    private var vsyncModeHandler: ((EditorVSyncMode) -> Void)?
    private var session: Session?
    private var pendingSessionProposal: Proposal?
    private let editLog: EditLog
    private var frameTimingAccumulator: Double = 0
    private var frameTimingCount: Int = 0
    private var frameTiming = EditorFrameTiming()

    public init(projectDirectory: String,
                backendConfig: WGPUDeviceConfig? = nil,
                backend: WGPUBackend? = nil,
                events: PlatformEventBridge = PlatformEventBridge(),
                initialAISettings: EditorAISettings = .default) throws {
        var resolvedBackendConfig = backendConfig ?? .init()
        if resolvedBackendConfig.libraryPath == nil {
            resolvedBackendConfig.libraryPath = Self.locateWGPUDylib()
        }
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
        let intentCoordinator = IntentRuntimeCoordinator()
        // Restore the AI backend from the settings passed in at launch (loaded from
        // EditorShellState by the caller) and the matching key in Keychain.
        store.dispatch(.setAISettings(initialAISettings))
        let initialSession = EditorApplication.makeSession(for: initialAISettings)

        self.engine = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: resolvedBackend)
        self.projectDirectory = projectDirectory
        self.store = store
        self.inputState = InputState()
        self.scene = scene
        self.observationBus = observationBus
        self.intentCoordinator = intentCoordinator
        self.events = events
        self.editLog = EditLog(projectDirectory: projectDirectory)
        self.session = initialSession

        // Bootstrap the session's entity index from the live scene.
        if let initialSession {
            let snapshot = SceneSemanticEncoder().encode(
                scene.scene,
                selectedEntityID: store.state.selectedEntityID,
                workspaceMode: store.state.workspaceMode.rawValue,
                localeIdentifier: nil
            )
            Task { await initialSession.observe(snapshot: snapshot) }
        }

        scene.onRevisionChanged = { revision in
            store.dispatch(.setSceneRevision(revision))
        }
        store.dispatch(.setSceneRevision(scene.revision))
        if let selection = scene.defaultSelectionID {
            store.dispatch(.setSelectedEntity(selection))
        }
    }

    public func bootstrap() {
        eventToken = events.subscribe { [weak self] event in
            self?.handlePlatformEvent(event)
        }
        engine.start(renderSurface: nil, enableViewportSurface: true)
        // 默认启用离屏渲染，让引擎渲染到一个 viewport 纹理交给编辑器显示。
        // 不开启 viewportResolve 时 UI 会一直停在 "Waiting for first render packet"。
        engine.queueRenderSettings(
            RenderSettings(stage: .r3ViewportInterop,
                           enableOffscreenViewport: true)
        )
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
            drawableSize: viewportDrawableSize,
            shouldRender: store.state.shouldRender,
            renderSceneOverride: scene.currentRenderScene()
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

    public func setViewportDrawableSize(_ size: RenderDrawableSize) {
        guard viewportDrawableSize != size else { return }
        viewportDrawableSize = size
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

    /// 把资产生成到场景中，并把新实体设为当前选中。
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

    /// 处理 AssetBrowser 在视口内放下资产的事件。如果当前光标坐标
    /// 落在视口矩形内则生成实体，否则只是清掉拖动状态。
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
        engine.queueRenderSettings(settings)
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
        store.dispatch(.setAIStatusMessage("Planning…"))

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let proposal = try await session.process(
                    .naturalLanguage(text: text, locale: locale ?? "en")
                )
                let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)

                guard !proposal.plan.isEmpty else {
                    self.store.dispatch(.setAIStatusMessage("No scene changes needed."))
                    return
                }

                let transaction = try SceneEditPlanExecutor().buildTransaction(
                    from: proposal.plan,
                    scene: self.scene.scene,
                    baseSceneRevision: proposal.baseSceneRevision,
                    approvalPolicy: proposal.approvalPolicy
                )
                _ = latencyMs
                self.pendingSessionProposal = proposal
                self.submitPlanTransaction(transaction)
            } catch {
                self.store.dispatch(.setAIStatusMessage(String(describing: error)))
            }
        }
    }

    private func submitPlanTransaction(_ transaction: TransactionIR) {
        if store.state.pendingConfirmationRequest != nil {
            store.dispatch(.setAIStatusMessage("Resolve the pending confirmation before submitting another AI action."))
            return
        }
        var context = makeExecutionContext()
        do {
            let result = try intentCoordinator.submitPlan(transaction, executionContext: &context)
            applyInvocationResult(result, executionContext: &context)
        } catch {
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings([]))
            store.dispatch(.setAIStatusMessage(String(describing: error)))
        }
    }

    public func dismissUnresolvedIntent(id: String) {}

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
            store.dispatch(.setAIStatusMessage(String(describing: error)))
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

    public static func locateWGPUDylib() -> String {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/Engine/vendor/wgpu/lib/libwgpu_native.dylib",
            "\(cwd)/Engine/vendor/wgpu/libwgpu_native.dylib",
            "\(cwd)/vendor/wgpu/lib/libwgpu_native.dylib",
            "\(cwd)/vendor/wgpu/libwgpu_native.dylib",
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            return c
        }
        return "libwgpu_native.dylib"
    }

    // MARK: - AI settings

    /// Applies new AI settings: persists provider/model, writes the key to Keychain,
    /// and hot-swaps the Session without restart.
    public func applyAISettings(_ settings: EditorAISettings, apiKey: String) {
        AIKeychain.save(key: apiKey, provider: settings.provider)
        store.dispatch(.setAISettings(settings))
        let newSession = Self.makeSession(for: settings)
        if let newSession {
            let snapshot = SceneSemanticEncoder().encode(
                scene.scene,
                selectedEntityID: store.state.selectedEntityID,
                workspaceMode: store.state.workspaceMode.rawValue,
                localeIdentifier: store.state.language.lprojName
            )
            Task { await newSession.observe(snapshot: snapshot) }
        }
        session = newSession
    }

    /// Removes the stored API key for the current provider and disables AI.
    public func clearAIKey() {
        AIKeychain.delete(provider: store.state.aiSettings.provider)
        session = nil
    }

    /// Returns `true` if a non-empty API key is stored for the current provider.
    public func hasStoredAIKey() -> Bool {
        AIKeychain.hasKey(for: store.state.aiSettings.provider)
    }

    static func makeSession(for settings: EditorAISettings) -> Session? {
        switch settings.provider {
        case .none:
            return nil
        case .anthropic:
            guard let key = AIKeychain.load(provider: .anthropic) else { return nil }
            let config = SessionConfig(apiKey: key, model: settings.model)
            return Session(config: config)
        }
    }

    private func submitResolvedIntent(_ intent: IntentIR) {
        do {
            let transaction = try intentTransactionBuilder.buildTransaction(from: intent,
                                                                            context: makeIntentTransactionBuildContext())
            submitPlanTransaction(transaction)
        } catch {
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings([]))
            store.dispatch(.setAIStatusMessage(String(describing: error)))
        }
    }

    private func makeIntentTransactionBuildContext() -> IntentTransactionBuildContext {
        IntentTransactionBuildContext(sceneRuntime: scene.scene,
                                      selectedEntityID: store.state.selectedEntityID,
                                      defaultSpawnMeshIndex: defaultSpawnMeshIndex())
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
            if var edit = result.applyResult?.edit {
                // Enrich provenance with the proposal that generated this edit.
                if let proposal = pendingSessionProposal {
                    edit.provenance.proposalID = proposal.id
                    let stepCount = proposal.plan.steps.count
                    let accepted = (0..<stepCount).map { "step_\($0)" }
                    if let session {
                        Task { await session.learn(proposalID: proposal.id,
                                                   acceptedStepIDs: accepted,
                                                   rejectedStepIDs: []) }
                    }
                    pendingSessionProposal = nil
                }
                editLog.append(edit)
                // Feed WorldEvents to keep Session's entity index current (Phase 5 delta path).
                if let session, let events = result.applyResult?.worldEvents, !events.isEmpty {
                    Task {
                        for event in events { await session.observe(event: event) }
                    }
                }
            }
        case .confirmationRequested:
            store.dispatch(.setPendingConfirmationRequest(result.confirmationRequest))
            store.dispatch(.setAIWarnings(result.warnings))
            store.dispatch(.setAIStatusMessage("Confirmation required for \(result.transactionID)"))
        case .discarded:
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings(result.warnings))
            store.dispatch(.setAIStatusMessage("Discarded \(result.transactionID)"))
            if let proposal = pendingSessionProposal {
                let stepCount = proposal.plan.steps.count
                let rejected = (0..<stepCount).map { "step_\($0)" }
                if let session {
                    Task { await session.learn(proposalID: proposal.id,
                                               acceptedStepIDs: [],
                                               rejectedStepIDs: rejected) }
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
