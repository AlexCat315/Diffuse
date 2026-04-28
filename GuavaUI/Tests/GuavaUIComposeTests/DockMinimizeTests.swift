import Foundation
import CoreGraphics
import Testing
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

@Suite("Dock minimize", .serialized)
struct DockMinimizeTests: GuavaUIComposeSerializedSuite {

    @Test("minimizeLeaf removes a leaf from root and stores it by edge")
    func minimizeLeafStoresLeaf() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))

        controller.apply(.minimizeLeaf(leafID: leafA.id, edge: .left))

        #expect(!controller.root.collectTabIDs().contains(tabA.id))
        #expect(controller.root.collectTabIDs() == [tabB.id])
        #expect(controller.minimizedLeaves[leafA.id]?.edge == .left)
        #expect(controller.minimizedLeaves[leafA.id]?.node.collectTabIDs() == [tabA.id])
        #expect(controller.minimizedOrder == [leafA.id])
    }

    @Test("restoreMinimizedLeaf reinserts the stored leaf")
    func restoreMinimizedLeaf() {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))

        controller.apply(.minimizeLeaf(leafID: leafA.id, edge: .left))
        controller.apply(.restoreMinimizedLeaf(leafA.id))

        #expect(controller.minimizedLeaves.isEmpty)
        #expect(controller.minimizedOrder.isEmpty)
        #expect(controller.root.collectTabIDs().contains(tabA.id))
        #expect(controller.root.collectTabIDs().contains(tabB.id))
    }

    @Test("minimizing the only root leaf leaves an empty dock and restores cleanly")
    func minimizeOnlyRootLeaf() {
        let tab = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([tab])
        let controller = DockController(root: leaf)

        controller.apply(.minimizeLeaf(leafID: leaf.id, edge: .bottom))
        guard case .empty = controller.root else {
            Issue.record("expected empty root after minimizing the only leaf")
            return
        }

        controller.apply(.restoreMinimizedLeaf(leaf.id))
        #expect(controller.root.collectTabIDs() == [tab.id])
    }

    @Test("minimize button sits on the trailing edge of the tab strip")
    func minimizeButtonSitsAtTrailingEdge() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "a", title: "A")
        let leaf = DockLayoutNode.tabs([tab])
        let controller = DockController(root: leaf)
        controller.onResolveMinimizedEdge = { leafID in
            leafID == leaf.id ? .left : nil
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: { key in
            AnyView(Text("content:\(key)"))
        }))
        graph.computeLayout(width: 600, height: 400)

        let buttons = collect(tree.root!) { node in
            node.attachments[_DockLeafMinimizeButtonHost.kMinimizeButtonMarker] as? Bool == true
        }
        #expect(buttons.count == 1)
        if let button = buttons.first {
            let frame = absoluteFrame(of: button)
            #expect(frame.minX > 560)
            #expect(frame.maxX <= 600)
        }
        _ = graph
    } }

    @Test("DockContainer renders a visible rail after minimizing a leaf")
    func containerRendersRailAfterMinimize() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        controller.onResolveMinimizedEdge = { leafID in
            leafID == leafA.id ? .left : nil
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: { key in
            AnyView(Text("content:\(key)"))
        }))
        graph.computeLayout(width: 600, height: 400)

        controller.apply(.minimizeLeaf(leafID: leafA.id, edge: .left))
        graph.recomposer.commitAll()
        graph.computeLayout(width: 600, height: 400)

        let rails = collect(tree.root!) { node in
            node.attachments[_DockMinimizedRail.kRailMarker] as? DockMinimizedEdge == .left
        }
        #expect(rails.count == 1)
        #expect((rails.first?.frame.width ?? 0) >= 35)
        #expect((rails.first?.frame.height ?? 0) >= 300)

        let restoreButtons = collect(tree.root!) { node in
            node.isHitTestable && node.cursor == .pointer
        }
        #expect(!restoreButtons.isEmpty)
        _ = graph
    } }

    @Test("side rail renders a vertical title bar for minimized leaves")
    func sideRailRendersVerticalTitleBar() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tabA = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let tabB = DockTab(userKey: "center", title: "Center")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        controller.onResolveMinimizedEdge = { leafID in
            leafID == leafA.id ? .left : nil
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: { key in
            AnyView(Text("content:\(key)"))
        }))
        graph.computeLayout(width: 600, height: 400)

        controller.apply(.minimizeLeaf(leafID: leafA.id, edge: .left))
        graph.recomposer.commitAll()
        graph.computeLayout(width: 600, height: 400)

        let title = collect(tree.root!) { node in
            node.attachments[_DockVerticalRailTitle.kTitleMarker] as? Bool == true
        }.first
        #expect(title?.attachments[_DockVerticalRailTitle.kTitleValue] as? String == "Hierarchy")
        #expect((title?.frame.height ?? 0) > (title?.frame.width ?? 0))
        #expect((title?.frame.height ?? 0) >= 72)
        _ = graph
    } }

    @Test("side rail renders every tab from a minimized multi-tab leaf")
    func sideRailRendersEveryTabInMinimizedLeaf() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let hierarchy = DockTab(userKey: "hierarchy", title: "Hierarchy")
        let assets = DockTab(userKey: "assets", title: "Assets")
        let center = DockTab(userKey: "center", title: "Center")
        let sideLeaf = DockLayoutNode.tabs([hierarchy, assets], active: assets.id)
        let centerLeaf = DockLayoutNode.tabs([center])
        let controller = DockController(root: .hsplit(first: sideLeaf, second: centerLeaf))
        controller.onResolveMinimizedEdge = { leafID in
            leafID == sideLeaf.id ? .left : nil
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: { key in
            AnyView(Text("content:\(key)"))
        }))
        graph.computeLayout(width: 600, height: 400)

        controller.apply(.minimizeLeaf(leafID: sideLeaf.id, edge: .left))
        graph.recomposer.commitAll()
        graph.computeLayout(width: 600, height: 400)

        let titles = collect(tree.root!) { node in
            node.attachments[_DockVerticalRailTitle.kTitleMarker] as? Bool == true
        }.compactMap {
            $0.attachments[_DockVerticalRailTitle.kTitleValue] as? String
        }
        #expect(titles == ["Hierarchy", "Assets"])

        controller.restoreMinimizedLeaf(sideLeaf.id, activating: hierarchy.id)
        guard case .split(_, _, _, let restored, _) = controller.root,
              case .tabs(_, _, let active) = restored else {
            Issue.record("expected restored side leaf")
            return
        }
        #expect(active == hierarchy.id)
        _ = graph
    } }

    @Test("minimized rails stay anchored to container edges")
    func minimizedRailsStayAnchoredToContainerEdges() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let leftTab = DockTab(userKey: "left", title: "Left")
        let centerTab = DockTab(userKey: "center", title: "Center")
        let bottomTab = DockTab(userKey: "bottom", title: "Bottom")
        let leftLeaf = DockLayoutNode.tabs([leftTab])
        let centerLeaf = DockLayoutNode.tabs([centerTab])
        let bottomLeaf = DockLayoutNode.tabs([bottomTab])
        let controller = DockController(root: .hsplit(
            first: leftLeaf,
            second: .vsplit(first: centerLeaf, second: bottomLeaf)
        ))
        controller.onResolveMinimizedEdge = { leafID in
            if leafID == leftLeaf.id { return .left }
            if leafID == bottomLeaf.id { return .bottom }
            return nil
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: { key in
            AnyView(Text("content:\(key)"))
        }))
        graph.computeLayout(width: 600, height: 400)

        controller.apply(.minimizeLeaf(leafID: leftLeaf.id, edge: .left))
        controller.apply(.minimizeLeaf(leafID: bottomLeaf.id, edge: .bottom))
        graph.recomposer.commitAll()
        graph.computeLayout(width: 600, height: 400)

        let leftRail = collect(tree.root!) { node in
            node.attachments[_DockMinimizedRail.kRailMarker] as? DockMinimizedEdge == .left
        }.first.map(absoluteFrame(of:))
        let bottomRail = collect(tree.root!) { node in
            node.attachments[_DockMinimizedRail.kRailMarker] as? DockMinimizedEdge == .bottom
        }.first.map(absoluteFrame(of:))

        #expect(leftRail?.minX == 0)
        #expect((leftRail?.width ?? 0) >= 39)
        #expect(bottomRail?.maxY == 400)
        #expect((bottomRail?.height ?? 0) >= 39)
        _ = graph
    } }

    private func collect(_ root: Node, where predicate: (Node) -> Bool) -> [Node] {
        var out: [Node] = []
        func walk(_ node: Node) {
            if predicate(node) { out.append(node) }
            for child in node.children { walk(child) }
        }
        walk(root)
        return out
    }

    private func absoluteFrame(of node: Node) -> CGRect {
        var origin = node.frame.origin
        var current = node.parent
        while let node = current {
            origin.x += node.frame.origin.x
            origin.y += node.frame.origin.y
            current = node.parent
        }
        return CGRect(origin: origin, size: node.frame.size)
    }
}
