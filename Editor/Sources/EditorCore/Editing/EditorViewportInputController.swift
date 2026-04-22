import Foundation

/// 视口相机拖拽 / 选择状态的全局持有者。
/// `ViewportPanel.handleViewportInput` 是值类型 view body 里的临时方法，
/// 没法持有状态；这里用单例承接跨事件的轻量上下文。
public final class EditorViewportInputController: @unchecked Sendable {
    public static let shared = EditorViewportInputController()
    private init() {}

    public enum CameraDrag { case orbit, pan }

    public var activeCameraDrag: CameraDrag?
    public var lastCursor: (x: Float, y: Float)?

    /// 鼠标按下时记录起点，以便释放时判断是否算 "click" 触发拾取。
    public var leftDownAt: (x: Float, y: Float)?

    public func reset() {
        activeCameraDrag = nil
        lastCursor = nil
        leftDownAt = nil
    }
}
