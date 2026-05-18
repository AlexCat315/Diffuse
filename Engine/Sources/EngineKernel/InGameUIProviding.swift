import Foundation

/// Engine 侧定义的游戏内 UI 抽象协议。
///
/// GuavaUI 将在未来实现此协议，为引擎提供菜单、文本、HUD 等能力。
/// Engine 永远不 import GuavaUI，依赖方向保持单向：
///
///   Editor → GuavaUI → Engine
///                ↑
///   GuavaUI 实现 InGameUIProviding，由外部注入 Engine
///
/// 这样彻底消除循环依赖。
public protocol InGameUIProviding: AnyObject, Sendable {
    /// Called after each 3D render pass with canvas commands and opaque GPU handles.
    ///
    /// - Parameters:
    ///   - canvas: Draw commands accumulated by scripts this frame.
    ///   - commandEncoder: Opaque `GPUCommandEncoder` — cast internally by the implementor.
    ///   - colorView: Opaque `GPUTextureView` for the final surface — render UI on top with loadOp=.load.
    ///   - formatHint: Surface texture format name ("bgra8Unorm", "rgba16Float", etc.).
    ///   - width: Drawable width in pixels.
    ///   - height: Drawable height in pixels.
    ///   - deltaTime: Frame delta time in seconds.
    func renderInGameUI(
        canvas: InGameCanvas,
        commandEncoder: AnyObject,
        colorView: AnyObject,
        formatHint: String,
        width: Int,
        height: Int,
        deltaTime: Double
    )

    /// Notifies the UI layer of a viewport resize.
    func notifyResize(width: Int, height: Int)
}

/// Engine 可选地持有一个 InGameUIProviding 实例。
/// GuavaUI 初始化完成后通过 setter 注入，解耦启动顺序。
public final class InGameUIRegistry: @unchecked Sendable {
    public static let shared = InGameUIRegistry()
    private var _provider: (any InGameUIProviding)?
    private let lock = NSLock()

    private init() {}

    public var provider: (any InGameUIProviding)? {
        get { lock.withLock { _provider } }
        set { lock.withLock { _provider = newValue } }
    }
}
