import XCTest
@testable import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace

@MainActor
final class PanelWorkspaceIntegrationTests: XCTestCase {
    func testPanelRegistryExportsTypedWorkspaceDescriptors() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "hierarchy",
                            title: "Hierarchy",
                            preferredSlot: .leading,
                            iconAssetKey: "hierarchy") { EmptyView() },
            PanelDescriptor(id: "inspector",
                            title: "Inspector",
                            preferredSlot: .trailing,
                            iconAssetKey: "inspector") { EmptyView() },
        ])

        let workspaceRegistry = registry.workspaceRegistry

        XCTAssertEqual(workspaceRegistry.descriptor(for: "hierarchy")?.defaultSlot, .leading)
        XCTAssertEqual(workspaceRegistry.descriptor(for: "inspector")?.defaultSlot, .trailing)
        XCTAssertEqual(workspaceRegistry.descriptor(for: "hierarchy")?.iconAssetKey, "hierarchy")
    }

    func testPanelWorkspaceRendersNewWorkspaceController() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "viewport",
                            title: "Viewport",
                            closable: false,
                            preferredSlot: .center) { Text("Viewport") },
            PanelDescriptor(id: "console",
                            title: "Console",
                            preferredSlot: .bottom) { Text("Console") },
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
                                                     bottom: .group("bottom")),
            layoutTree: .group("center")
        ))

        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: PanelWorkspace(controller: controller, registry: registry))
        graph.computeLayout(width: 800, height: 600)

        let snapshot = graph.layoutSnapshot()
        XCTAssertTrue(snapshot.contains(where: { $0.debugName == "workspace" }))
        XCTAssertTrue(snapshot.contains(where: { $0.debugName == "workspace-region-center" }))
        XCTAssertTrue(snapshot.contains(where: { $0.debugName == "workspace-region-bottom" }))
    }
}
