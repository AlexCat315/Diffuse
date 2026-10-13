import XCTest
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace

final class PanelWorkspaceIntegrationTests: XCTestCase {
    func testPanelRegistryExportsTypedWorkspaceDescriptors() {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "hierarchy", title: "Hierarchy", defaultSlot: .leading, configure: { $0.isCollapsible = true; $0.iconAssetKey = "hierarchy" }) { EmptyView() },
            WorkspacePanelDescriptor(id: "inspector", title: "Inspector", defaultSlot: .trailing, configure: { $0.isCollapsible = true; $0.iconAssetKey = "inspector" }) { EmptyView() },
        ])

        let workspaceRegistry = registry

        XCTAssertEqual(workspaceRegistry.descriptor(for: "hierarchy")?.defaultSlot, .leading)
        XCTAssertEqual(workspaceRegistry.descriptor(for: "inspector")?.defaultSlot, .trailing)
        XCTAssertEqual(workspaceRegistry.descriptor(for: "hierarchy")?.panel.iconAssetKey, "hierarchy")
    }

    func testPanelWorkspaceRendersNewWorkspaceController() {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "viewport", title: "Viewport", defaultSlot: .center, configure: { $0.isCollapsible = false; $0.isClosable = false }) { Text("Viewport") },
            WorkspacePanelDescriptor(id: "console", title: "Console", defaultSlot: .bottom, configure: { $0.isCollapsible = true }) { Text("Console") },
        ])
        let controller = WorkspaceController(document: WorkspaceDocument(
            panels: [
                "viewport": WorkspacePanel(id: "viewport", title: "Viewport", isClosable: false),
                "console": WorkspacePanel(id: "console", title: "Console"),
            ],
            groups: [
                "center": WorkspaceTabGroup(id: "center", panels: ["viewport"], activePanelID: "viewport"),
                "bottom": WorkspaceTabGroup(id: "bottom", panels: ["console"], activePanelID: "console"),
            ],
            slots: WorkspaceSlot.standardEditorSlots(center: .group("center"),
                                                     bottom: .group("bottom"))))

        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: WorkspaceView(controller: controller, registry: registry))
        graph.computeLayout(width: 800, height: 600)

        let snapshot = graph.layoutSnapshot()
        XCTAssertTrue(snapshot.contains(where: { $0.debugName == "workspace" }))
        XCTAssertTrue(snapshot.contains(where: { $0.debugName == "workspace-region-center" }))
        XCTAssertTrue(snapshot.contains(where: { $0.debugName == "workspace-region-bottom" }))
    }
}
