import EngineCore
import EngineKernel
import RenderBackend
import RHIWGPU
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
@MainActor
public final class EditorApplication {
    public let engine: EngineHost
    public let store: EditorStore
    public let inputState: InputState

    public init(backendConfig: WGPUDeviceConfig? = nil) {
        var resolvedBackendConfig = backendConfig ?? .init()
        if resolvedBackendConfig.libraryPath == nil {
            resolvedBackendConfig.libraryPath = Self.locateWGPUDylib()
        }
        let backend = WGPUBackend(config: resolvedBackendConfig)
        self.engine = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: backend)
        self.store = EditorStore()
        self.inputState = InputState()
    }

    public func bootstrap() {
        engine.start(renderSurface: nil)
        store.dispatch(.setConnected(true))
    }

    public func tick(deltaTime: Double) {
        engine.tick(
            deltaTime: deltaTime,
            inputEvents: [],
            drawableSize: .init(),
            shouldRender: store.state.shouldRender
        )
    }

    public func shutdown() {
        engine.shutdown()
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

    private static func locateWGPUDylib() -> String {
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
