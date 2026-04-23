import AssetPipeline
import EngineCore
import EngineKernel
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
public final class EditorApplication {
    public let engine: EngineHost
    public let projectDirectory: String
    public let store: EditorStore
    public let inputState: InputState
    public let scene: EditorSceneAdapter

    private let events: PlatformEventBridge
    private var eventToken: PlatformEventBridge.SubscriptionToken?
    private var pendingViewportEvents: [InputEvent] = []
    private var viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)

    public init(projectDirectory: String,
                backendConfig: WGPUDeviceConfig? = nil,
                backend: WGPUBackend? = nil,
                events: PlatformEventBridge = PlatformEventBridge()) throws {
        var resolvedBackendConfig = backendConfig ?? .init()
        if resolvedBackendConfig.libraryPath == nil {
            resolvedBackendConfig.libraryPath = Self.locateWGPUDylib()
        }
        let resolvedBackend = backend ?? WGPUBackend(config: resolvedBackendConfig)
        _ = try EditorAssetCatalog.loadProject(at: projectDirectory)
        let store = EditorStore()
        let scene = EditorSceneAdapter()

        self.engine = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: resolvedBackend)
        self.projectDirectory = projectDirectory
        self.store = store
        self.inputState = InputState()
        self.scene = scene
        self.events = events

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
    }

    public func tick(deltaTime: Double) {
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
    }

    public func shutdown() {
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

    /// 把资产生成到场景中，并把新实体设为当前选中。
    @discardableResult
    public func spawnAsset(_ asset: EditorAsset, at position: SIMD3<Float> = .zero) -> UInt64? {
        guard let id = scene.spawnEntity(from: asset, at: position) else {
            return nil
        }
        store.dispatch(.setSelectedEntity(id))
        return id
    }

    /// 处理 AssetBrowser 在视口内放下资产的事件。如果当前光标坐标
    /// 落在视口矩形内则生成实体，否则只是清掉拖动状态。
    @discardableResult
    public func handleAssetDrop(at cursorX: Float, cursorY: Float) -> Bool {
        guard let payload = store.state.activeAssetDrag else { return false }
        defer { store.dispatch(.endAssetDrag) }
        guard let frame = EditorViewportDropTarget.frame,
              frame.contains(x: cursorX, y: cursorY)
        else {
            return false
        }
        guard let asset = EditorAssetCatalog.asset(for: payload.assetID) else {
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

    public func currentRenderStats() -> RenderFrameStats {
        engine.currentRenderStats()
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        engine.currentViewportSurfaceState()
    }

    private func handlePlatformEvent(_ event: InputEvent) {
        switch event {
        case .windowFocusGained:
            store.dispatch(.setWindowFocused(true))
        case .windowFocusLost:
            store.dispatch(.setWindowFocused(false))
        case .windowMinimized:
            store.dispatch(.setWindowMinimized(true))
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
}
