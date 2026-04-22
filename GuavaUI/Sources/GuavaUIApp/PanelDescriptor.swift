import GuavaUICompose

/// 面板描述符：把面板的元数据与构建闭包合并为一份注册项。
///
/// `factory` 会在 `PanelWorkspace` 解析对应 `DockTab.userKey` 时按需调用，
/// 因此持有面板状态的对象必须由调用方在 `factory` 之外管理（典型做法是
/// 通过闭包捕获 store/service 引用）。
public struct PanelDescriptor {
    public let id: String
    public var title: String
    public var closable: Bool
    /// 视图构建闭包。GuavaUIApp 在 `Recomposer.commitAll()` /
    /// `ViewGraph.materialise` 路径上同步调用它，调用线程与窗口主循环线程
    /// 一致。闭包内可以自由读取主线程持有的 store / controller。
    public let factory: () -> AnyView

    public init(id: String,
                title: String,
                closable: Bool = true,
                factory: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.closable = closable
        self.factory = factory
    }

    /// 便捷初始化：直接接收 `@ViewBuilder` 闭包，避免调用方手写 `AnyView`。
    public init<Content: View>(id: String,
                               title: String,
                               closable: Bool = true,
                               @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id,
                  title: title,
                  closable: closable,
                  factory: { AnyView(content()) })
    }
}
