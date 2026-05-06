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
                            preferredRegion: .leading,
                            iconAssetKey: "hierarchy") { EmptyView() },
            PanelDescriptor(id: "inspector",
                            title: "Inspector",
                            preferredRegion: .trailing,
                            iconAssetKey: "inspector") { EmptyView() },
        ])

        let workspaceRegistry = registry.workspaceRegistry

        XCTAssertEqual(workspaceRegistry.descriptor(for: "hierarchy")?.defaultRegion, .leading)
        XCTAssertEqual(workspaceRegistry.descriptor(for: "inspector")?.defaultRegion, .trailing)
        XCTAssertEqual(workspaceRegistry.descriptor(for: "hierarchy")?.iconAssetKey, "hierarchy")
    }

    func testPanelWorkspaceRendersNewWorkspaceController() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "viewport",
                            title: "Viewport",
                            closable: false,
                            preferredRegion: .center) { Text("Viewport") },
            PanelDescriptor(id: "console",
                            title: "Console",
                            preferredRegion: .bottom) { Text("Console") },
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
            regions: [
                WorkspaceRegion(id: .leading),
                WorkspaceRegion(id: .center, layout: .group("center")),
                WorkspaceRegion(id: .trailing),
                WorkspaceRegion(id: .bottom, layout: .group("bottom")),
            ]
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
