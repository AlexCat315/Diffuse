import CoreGraphics
import EngineKernel
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Dock drop guide overlay")
struct DockDropGuideOverlayTests {

    @Test("Lift-tier drop hit draws guide tiles near the leaf centre")
    func liftTierDrawsGuideTiles() {
        let controller = DockController(root: .tabs([DockTab(userKey: "a", title: "A")]))
        let sourceLeafID = DockNodeID()
        let targetLeafID = DockNodeID()
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let registry = DockHitRegistry()
        registry.register(nodeID: targetLeafID, node: node)
        installDropOverlay(node: node, leafID: targetLeafID, controller: controller)

        controller.dragSession.start(tabID: DockTabID(),
                                     sourceLeafID: sourceLeafID,
                                     ghost: DockDragSession.GhostInfo(title: "A"),
                                     x: 8,
                                     y: 8,
                                     intent: .detachOrSplit)
        controller.dragSession.updatePointer(x: 110, y: 80, registry: registry)

        let list = DrawList()
        node.overlayDraw?(list, .zero)

        #expect(list.vertices.contains {
            $0.posX >= 70 && $0.posX <= 150 && $0.posY >= 40 && $0.posY <= 120
        })
        #expect(list.vertices.count > 20)
    }

    @Test("Source leaf centre keeps the guide visible even when center drop is a no-op")
    func sourceLeafCentreStillShowsGuide() {
        let targetLeafID = DockNodeID()
        let controller = DockController(root: .tabs([DockTab(userKey: "a", title: "A")]))
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let registry = DockHitRegistry()
        registry.register(nodeID: targetLeafID, node: node)
        installDropOverlay(node: node, leafID: targetLeafID, controller: controller)

        controller.dragSession.start(tabID: DockTabID(),
                                     sourceLeafID: targetLeafID,
                                     ghost: DockDragSession.GhostInfo(title: "A"),
                                     x: 8,
                                     y: 8,
                                     intent: .detachOrSplit)
        controller.dragSession.updatePointer(x: 110, y: 80, registry: registry)

        #expect(controller.dragSession.dropHit == nil)
        #expect(controller.dragSession.hoverLeafID == targetLeafID)

        let list = DrawList()
        node.overlayDraw?(list, .zero)

        #expect(list.vertices.contains {
            $0.posX >= 70 && $0.posX <= 150 && $0.posY >= 40 && $0.posY <= 120
        })
    }

    @Test("Reorder-tier drag keeps the guide hidden")
    func reorderTierKeepsGuideHidden() {
        let controller = DockController(root: .tabs([DockTab(userKey: "a", title: "A")]))
        let sourceLeafID = DockNodeID()
        let targetLeafID = DockNodeID()
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let registry = DockHitRegistry()
        registry.register(nodeID: targetLeafID, node: node)
        installDropOverlay(node: node, leafID: targetLeafID, controller: controller)

        controller.dragSession.start(tabID: DockTabID(),
                                     sourceLeafID: sourceLeafID,
                                     ghost: DockDragSession.GhostInfo(title: "A"),
                                     x: 8,
                                     y: 8,
                                     intent: .reorderInStrip)
        controller.dragSession.updatePointer(x: 110, y: 80, registry: registry)

        let list = DrawList()
        node.overlayDraw?(list, .zero)

        #expect(list.vertices.isEmpty)
    }

    @Test("Workspace-scoped preview suppresses the leaf overlay")
    func workspaceScopedPreviewSuppressesLeafOverlay() {
        let root = DockLayoutNode.tabs([DockTab(userKey: "a", title: "A")])
        let controller = DockController(root: root)
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let registry = DockHitRegistry()
        registry.registerRoot(nodeID: root.id, node: node)
        registry.register(nodeID: root.id, node: node)
        installDropOverlay(node: node, leafID: root.id, controller: controller)

        controller.dragSession.start(tabID: DockTabID(),
                                     sourceLeafID: DockNodeID(),
                                     ghost: DockDragSession.GhostInfo(title: "A"),
                                     x: 8,
                                     y: 8,
                                     intent: .detachOrSplit)
        let bottomTile = makeWorkspaceDropGuideTiles(in: UIRect(x: 0, y: 0, width: 600, height: 400))
            .first(where: { $0.edge == .bottom })
        #expect(bottomTile != nil)
        guard let bottomTile else { return }

        controller.dragSession.updatePointer(
            x: bottomTile.buttonRect.x + bottomTile.buttonRect.width * 0.5,
            y: bottomTile.buttonRect.y + bottomTile.buttonRect.height * 0.5,
            registry: registry
        )

        #expect(controller.dragSession.dropHit?.scope == .workspace)

        let list = DrawList()
        node.overlayDraw?(list, .zero)

        #expect(list.vertices.isEmpty)
    }
}
