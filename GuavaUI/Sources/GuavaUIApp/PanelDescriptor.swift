import GuavaUICompose
import GuavaUIWorkspace

/// Canonical top-level workspace region for a tool panel.
public typealias PanelID = WorkspacePanelID
public typealias PanelWorkspaceRegion = WorkspaceRegionID

/// 面板描述符：把面板的元数据与构建闭包合并为一份注册项。
public struct PanelDescriptor {
    public let id: PanelID
    public var title: String
    public var closable: Bool
    public var preferredRegion: PanelWorkspaceRegion
    public var iconAssetKey: String?
    /// 视图构建闭包。GuavaUIApp 在 `Recomposer.commitAll()` /
    /// `ViewGraph.materialise` 路径上同步调用它，调用线程与窗口主循环线程
    /// 一致。闭包内可以自由读取主线程持有的 store / controller。
    public let factory: () -> AnyView

    public init(id: PanelID,
                title: String,
                closable: Bool = true,
                preferredRegion: PanelWorkspaceRegion = .center,
                iconAssetKey: String? = nil,
                factory: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.closable = closable
        self.preferredRegion = preferredRegion
        self.iconAssetKey = iconAssetKey
        self.factory = factory
    }

    /// 便捷初始化：直接接收 `@ViewBuilder` 闭包，避免调用方手写 `AnyView`。
    public init<Content: View>(id: PanelID,
                               title: String,
                               closable: Bool = true,
                               preferredRegion: PanelWorkspaceRegion = .center,
                               iconAssetKey: String? = nil,
                               @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id,
                  title: title,
                  closable: closable,
                  preferredRegion: preferredRegion,
                  iconAssetKey: iconAssetKey,
                  factory: { AnyView(content()) })
    }

    public var workspaceDescriptor: WorkspacePanelDescriptor {
        WorkspacePanelDescriptor(id: id,
                                 title: title,
                                 defaultRegion: preferredRegion,
                                 isClosable: closable,
                                 isCollapsible: preferredRegion != .center,
                                 iconAssetKey: iconAssetKey,
                                 factory: factory)
    }
}
