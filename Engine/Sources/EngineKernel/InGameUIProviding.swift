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
    /// 每帧由引擎调用，用于提交游戏内 UI 绘制命令。
    func renderInGameUI(deltaTime: Double)

    /// 通知 UI 层窗口尺寸变化。
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
