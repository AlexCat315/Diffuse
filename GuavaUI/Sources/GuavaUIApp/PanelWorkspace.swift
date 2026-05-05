import GuavaUICompose
import GuavaUIWorkspace

/// 面向编辑器/工具应用的工作台根视图。
///
/// 把 `WorkspaceController` 与 `PanelRegistry` 绑在一起，调用方不再手动
/// 管理 Dock tree / tab key / layout normalizer。
public struct PanelWorkspace: View {
    public let controller: WorkspaceController
    public let registry: PanelRegistry

    public init(controller: WorkspaceController,
                registry: PanelRegistry) {
        self.controller = controller
        self.registry = registry
    }

    public var body: some View {
        WorkspaceView(controller: controller) { [registry] key in
            registry.make(key)
        }
    }
}
