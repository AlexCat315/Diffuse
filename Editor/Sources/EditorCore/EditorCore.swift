import EngineCore
import EngineKernel
import RenderBackend
import RHIWGPU
import GuavaUIRuntime
import Foundation

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
    public let store: EditorStore
    public let inputState: InputState
    public let scene: EditorSceneAdapter

    private let events: PlatformEventBridge
    private var eventToken: PlatformEventBridge.SubscriptionToken?
    private var pendingViewportEvents: [InputEvent] = []
    private var viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)

    public init(backendConfig: WGPUDeviceConfig? = nil,
                backend: WGPUBackend? = nil,
                events: PlatformEventBridge = PlatformEventBridge()) {
        var resolvedBackendConfig = backendConfig ?? .init()
        if resolvedBackendConfig.libraryPath == nil {
            resolvedBackendConfig.libraryPath = Self.locateWGPUDylib()
        }
        let resolvedBackend = backend ?? WGPUBackend(config: resolvedBackendConfig)
        let store = EditorStore()
        let scene = EditorSceneAdapter()

        self.engine = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: resolvedBackend)
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
        store.dispatch(.setConnected(true))
    }

    public func tick(deltaTime: Double) {
        let inputEvents = pendingViewportEvents
        pendingViewportEvents.removeAll(keepingCapacity: true)
        inputState.process(inputEvents)
        engine.tick(
            deltaTime: deltaTime,
            inputEvents: inputEvents,
            drawableSize: viewportDrawableSize,
            shouldRender: store.state.shouldRender
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
