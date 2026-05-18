import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import RHIWGPU

/// High-level in-game UI host that wires the full GuavaUI `ViewGraph` pipeline
/// for rendering 2-D HUD overlays on top of a 3-D scene.
///
/// ## Usage
///
/// ```swift
/// // During editor / game bootstrap (main thread):
/// let host = InGameUIHost(backend: wgpuBackend)
/// InGameUIRegistry.shared.provider = host
/// host.setRootView(MyGameHUD())
///
/// // In the main-thread tick (called every frame before rendering):
/// host.tick(width: viewportWidth, height: viewportHeight)
/// ```
///
/// Game logic drives the HUD by mutating `@Observable` objects that the root
/// `View` observes — no per-frame imperative drawing calls required.
///
/// ## Threading
/// - `setRootView` and `tick` must be called on the **main thread**.
/// - `renderInGameUI` (via `InGameUIProviding`) is called on the **render thread**
///   and reads the last snapshot published by `tick`.
public final class InGameUIHost: InGameUIProviding, @unchecked Sendable {

    private let bridge: InGameViewGraphBridge
    private let renderer: InGameUIRenderer

    public init(backend: WGPUBackend) {
        let source = InGameDrawListSource()
        let drawListRenderer = DrawListRenderer(backend: backend)
        self.bridge = InGameViewGraphBridge(source: source)
        self.renderer = InGameUIRenderer(renderer: drawListRenderer, source: source)
    }

    // MARK: - Main-thread API

    /// Install a GuavaUI `View` tree as the in-game HUD.
    /// Call once before the first `tick`. Ignored on subsequent calls.
    public func setRootView<V: View>(_ view: V) {
        bridge.setRootView(view)
    }

    /// Advance the in-game UI one frame. Call on the **main thread** every
    /// frame — typically inside the `onTick` callback passed to `AppRuntime.run`.
    public func tick(width: Int, height: Int) {
        bridge.tick(width: width, height: height)
    }

    // MARK: - InGameUIProviding (render thread)

    public func renderInGameUI(
        canvas: InGameCanvas,
        commandEncoder: AnyObject,
        colorView: AnyObject,
        formatHint: String,
        width: Int,
        height: Int,
        deltaTime: Double
    ) {
        renderer.renderInGameUI(
            canvas: canvas,
            commandEncoder: commandEncoder,
            colorView: colorView,
            formatHint: formatHint,
            width: width,
            height: height,
            deltaTime: deltaTime
        )
    }

    public func notifyResize(width: Int, height: Int) {}
}
