import GuavaUICompose
import GuavaUIWorkspace

/// 面向编辑器/工具应用的工作台根视图。
///
/// 把 `WorkspaceController` 与 `PanelRegistry` 绑在一起，调用方不再手动
/// 管理布局树 / tab key / layout normalizer。
public struct PanelWorkspace: View {
    public let controller: WorkspaceController
    public let registry: PanelRegistry
    public let compact: Bool

    public init(controller: WorkspaceController,
                registry: PanelRegistry, compact: Bool = false) {
        self.controller = controller
        self.registry = registry
        self.compact = compact
    }

    public var body: some View {
        WorkspaceView(controller: controller, compact: compact) { [registry] key in
            registry.make(key)
        }
    }
}
