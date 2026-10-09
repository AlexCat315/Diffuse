import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import RHIWGPU
import NativeRHI
import RenderBackend

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
/// - `recordInGameUI` (via `InGameUIProviding`) is called on the **render thread**
///   and reads the last snapshot published by `tick`.
public final class InGameUIHost: InGameUIProviding, @unchecked Sendable {

    private let bridge: InGameViewGraphBridge
    private let renderer: any InGameUIProviding

    public init(backend: WGPUBackend) {
        let source = InGameDrawListSource()
        let drawListRenderer = DrawListRenderer(backend: backend)
        self.bridge = InGameViewGraphBridge(source: source)
        self.renderer = WGPUInGameUIRenderer(renderer: drawListRenderer, source: source)
    }

    /// Native HUD and scene must share the same device and active frame.
    public init(device: Device) throws {
        let source = InGameDrawListSource()
        self.bridge = InGameViewGraphBridge(source: source)
        self.renderer = try NativeInGameUIRenderer(device: device, source: source)
    }

    // MARK: - Main-thread API

    /// Install a GuavaUI `View` tree as the in-game HUD.
    /// Call once before the first `tick`. Ignored on subsequent calls.
    public func setRootView<V: View>(_ view: V) {
        bridge.setRootView(view)
    }

    /// Advance the in-game UI one frame. Call on the **main thread** every
    /// frame — typically inside the `onTick` callback passed to `AppRuntime.run`.
    /// `width`/`height` are logical points; pass the window's content scale so
    /// HUD text rasterizes at physical-pixel resolution.
    public func tick(width: Int, height: Int, contentScale: Float = 1,
                     canvas: InGameCanvas = InGameCanvas()) {
        bridge.tick(width: width, height: height, contentScale: contentScale, canvas: canvas)
    }

    // MARK: - InGameUIProviding (render thread)

    public func recordInGameUI(packet: RenderPacket, target: InGameUIRenderTarget) throws -> InGameUIRecording? {
        try renderer.recordInGameUI(packet: packet, target: target)
    }
}
