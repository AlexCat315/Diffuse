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
    public func setViewportMode(_ mode: EditorViewportMode) {
        guard mode == .scene || store.workspaceMode.isGameWorkspace else { return }
        guard mode != store.viewportMode else { return }
        EditorViewportInputController.shared.reset()
        if mode == .scene, store.playbackState != .stopped { applyPlaybackState(.stopped) }
        store.dispatch(.setViewportMode(mode))
        scene.setEditorViewportCameraEnabled(mode == .scene)
        enqueueViewportInput(.windowFocusLost)
        queueTrackedRenderSettings(makeViewportRenderSettings(shadowsEnabled: store.viewportShadowsEnabled,
                                                               shadingMode: store.viewportShadingMode))
        requestDisplayRefresh()
    }

    public func setGamePreviewResolution(_ resolution: EditorGamePreviewResolution) {
        store.dispatch(.setGamePreviewResolution(resolution))
        requestDisplayRefresh()
    }

    public func setGamePreviewHUDEnabled(_ enabled: Bool) {
        store.dispatch(.setGamePreviewHUDEnabled(enabled))
        renderSettingsGeneration &+= 1
        requestDisplayRefresh()
    }
    public func enqueueViewportInput(_ event: InputEvent) {
        pendingViewportEvents.append(event)
        displayInvalidationHandler?()
    }

    /// Presentation size of the viewport in physical pixels (reported by
    /// `ViewportHost`). The engine renders this scaled by the render-scale
    /// settings — see `effectiveViewportDrawableSize()`.
    public var viewportDrawableSize: RenderDrawableSize { _viewportDrawableSize }

    func driveContinuousViewportCamera(deltaTime: Double) {
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
        // Layout can report a new size after the engine tick has already run.
        // In event-driven mode there may be no further input to wake it again.
        displayInvalidationHandler?()
    }

    func effectiveViewportDrawableSize() -> RenderDrawableSize {
        let state = store.state
        if state.viewportMode == .game { return state.gamePreviewResolution.size ?? _viewportDrawableSize }
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

    func monotonicNow() -> Double {
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

    /// Projects onto the current reference grid plane for viewport asset drops.
    /// Parallel or backward rays use the editor camera's focus point.
    func dropWorldPosition(cursorX: Float,
                           cursorY: Float,
                           frame: ViewportScreenFrame) -> SIMD3<Float> {
        let camera = scene.currentRenderCamera()
        guard let projection = EditorViewportProjection(camera: camera, frame: frame) else { return .zero }
        let ray = projection.cursorRay(x: cursorX, y: cursorY)
        let normal = EditorGridPlane.make(camera: camera).normal
        let denominator = simd_dot(ray.direction, normal)
        guard abs(denominator) > 1e-4 else { return camera.target }
        let t = -simd_dot(ray.origin, normal) / denominator
        guard t >= 0, t <= 10_000 else { return camera.target }
        return ray.origin + ray.direction * t
    }

    public func queueViewportRenderSettings(_ settings: RenderSettings) {
        var settings = settings
        settings.enableEditorGrid = store.state.viewportGridEnabled
        settings.editorGridSpacing = viewportGridSpacing
        queueTrackedRenderSettings(settings)
    }

    /// Single funnel for render-settings changes: bumps the generation the
    /// viewport render gate folds into its dirty signature.
    func queueTrackedRenderSettings(_ settings: RenderSettings) {
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

    public func setViewportGridEnabled(_ enabled: Bool) {
        guard store.state.viewportGridEnabled != enabled else { return }
        store.dispatch(.setViewportGridEnabled(enabled))
        var settings = lastQueuedRenderSettings
        settings.enableEditorGrid = enabled
        queueTrackedRenderSettings(settings)
        requestDisplayRefresh()
    }

    private var viewportGridSpacing: Float {
        store.state.translateSnapEnabled ? store.state.translateSnapStep : 1
    }

    func restoreAndObserveViewportSnapSettings() {
        let url = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava/editor-snap-settings.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(EditorViewportSnapSettings.self, from: data) {
            saved.restore(in: store)
        }
        var previous = EditorViewportSnapSettings(state: store.state)
        snapSettingsToken = store.subscribe { [weak self] store in
            let next = EditorViewportSnapSettings(state: store.state)
            guard let self, next != previous else { return }
            previous = next
            do {
                try JSONEncoder().encode(next).write(to: url, options: .atomic)
            } catch {
                self.logConsole("Could not save viewport snap settings", severity: .warning,
                                detail: error.localizedDescription)
            }
            var settings = self.lastQueuedRenderSettings
            settings.editorGridSpacing = self.viewportGridSpacing
            if settings != self.lastQueuedRenderSettings {
                self.queueTrackedRenderSettings(settings)
            }
            self.requestDisplayRefresh()
        }
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

    func makeViewportRenderSettings(
        shadowsEnabled: Bool,
        shadingMode: EditorViewportShadingMode
    ) -> RenderSettings {
        RenderSettings(
            stage: .r4LightingPBRShadow,
            debugViewMode: RenderSettings.DebugViewMode(rawValue: shadingMode.debugViewIndex) ?? .shaded,
            shadowSettings: RenderShadowSettings(enabled: shadowsEnabled),
            enableOffscreenViewport: true,
            enableEditorGrid: store.state.viewportGridEnabled && store.state.viewportMode == .scene,
            editorGridSpacing: viewportGridSpacing
        )
    }

    public func currentSelectedEntityTranslation() -> SIMD3<Float>? {
        guard let entity = entityID(from: store.state.selectedEntityID) else {
            return nil
        }
        return scene.scene.localTransform(for: entity)?.translation
    }

    func handlePlatformEvent(_ event: InputEvent) {
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
}
