import EditorCore
import GuavaUIApp
import GuavaUICompose

/// 编辑器根视图。装配 `DockController` + `PanelRegistry` + 一个三列 `PanelWorkspace`。
struct EditorRootView: View {
    let app: EditorApplication
    let controller: DockController
    let registry: PanelRegistry

    var body: some View {
        PanelWorkspace(controller: controller, registry: registry)
            .appearance(.dark)
    }
}

@MainActor
enum EditorRootViewFactory {
    static func makeController() -> DockController {
        let hierarchyTab = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let inspectorTab = DockTab(userKey: "inspector", title: "Inspector")
        let viewportTab = DockTab(userKey: "viewport", title: "Viewport", isClosable: false)
        let consoleTab = DockTab(userKey: "console", title: "Console")

        let hierarchyLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [hierarchyTab],
            activeTabID: hierarchyTab.id
        )
        let inspectorLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [inspectorTab],
            activeTabID: inspectorTab.id
        )
        let viewportLeaf: DockLayoutNode = .tabs(
            id: DockNodeID(),
            tabs: [viewportTab, consoleTab],
            activeTabID: viewportTab.id
        )

        let centerAndRight: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: 0.78,
            first: viewportLeaf,
            second: inspectorLeaf
        )
        let root: DockLayoutNode = .split(
            id: DockNodeID(),
            axis: .horizontal,
            fraction: 0.22,
            first: hierarchyLeaf,
            second: centerAndRight
        )
        return DockController(root: root)
    }

    static func makeRegistry(app: EditorApplication) -> PanelRegistry {
        PanelRegistry([
            PanelDescriptor(id: "hierarchy", title: "Hierarchy") {
                HierarchyPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "inspector", title: "Inspector") {
                InspectorPanel(store: app.store, scene: app.scene)
            },
            PanelDescriptor(id: "viewport", title: "Viewport", closable: false) {
                ViewportPanel(app: app, scene: app.scene)
            },
            PanelDescriptor(id: "console", title: "Console") {
                ConsolePanel(store: app.store)
            },
        ])
    }
}
