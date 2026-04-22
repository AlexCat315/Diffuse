import GuavaUICompose

/// 面向编辑器/工具应用的工作台根视图。
///
/// 把 `DockController` 与 `PanelRegistry` 绑在一起，调用方不再直接拼装
/// `DockContainer(controller:content:)`，也不再手维护 `DockTab.userKey`
/// 到面板视图的解析闭包。
public struct PanelWorkspace: View {
    public let controller: DockController
    public let registry: PanelRegistry
    public let hostBridge: DockHostBridge?

    public init(controller: DockController,
                registry: PanelRegistry,
                hostBridge: DockHostBridge? = nil) {
        self.controller = controller
        self.registry = registry
        self.hostBridge = hostBridge
    }

    public var body: some View {
        DockContainer(controller: controller, hostBridge: hostBridge) { [registry] key in
            registry.make(key)
        }
    }
}
