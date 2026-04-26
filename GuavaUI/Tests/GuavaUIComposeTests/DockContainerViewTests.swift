import Testing
import CoreGraphics
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Verifies that `DockContainer` produces the right primitive tree for a
/// given `DockController.root`, and that controller mutations recompose
/// the view through the subscription wired in `_StatefulDockContainer`.
@Suite("Phase 8 / DockContainer view tree", .serialized)
struct DockContainerViewTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in
            AnyView(Text("content:\(key)"))
        }
    }

    @Test("Tabs leaf renders one tab strip and one content slot")
    func tabsLeafShape() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "explorer", title: "Explorer")
        let controller = DockController(root: .tabs([tab]))

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))

        // Container → _StatefulDockContainer → _DockNodeView → tabs leaf Box.
        // The tabs leaf is a vertical Box with two children: tab strip + content.
        let leaf = firstNonWrapper(tree.root!)
        #expect(leaf.children.count == 2)
        _ = graph
    } }

    @Test("Split leaf renders first / handle / second in order")
    func splitLeafShape() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(
            root: .hsplit(fraction: 0.4,
                          first: .tabs([a]),
                          second: .tabs([b]))
        )

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))

        let split = firstNonWrapper(tree.root!)
        #expect(split.children.count == 3)
        _ = graph
    } }

    @Test("Controller mutation recomposes the view")
    func controllerRecompose() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: DockContainer(controller: controller, content: makeContent()))

        let leafBefore = firstNonWrapper(tree.root!)
        #expect(leafBefore.children.count == 2)

        // Wrap the leaf into a horizontal split. Recompose should switch the
        // top-level node from a tabs Box (2 children) to a split Box (3).
        controller.replace(root: .hsplit(
            fraction: 0.5,
            first: .tabs([tab]),
            second: .empty()
        ))
        recomp.commitAll()

        let after = firstNonWrapper(tree.root!)
        #expect(after.children.count == 3)
        _ = graph
    } }

    @Test("Tab click dispatches setActive to controller")
    func tabClickActivates() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(root: .tabs([a, b], active: a.id))

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: DockContainer(controller: controller, content: makeContent()))

        // Drive setActive directly through the controller — the click path
        // (Button → action closure → controller.apply) is exercised in
        // ButtonPressRecomposeTests; here we focus on D1's recompose loop.
        controller.apply(.setActive(node: rootLeafID(of: controller), tab: b.id))
        recomp.commitAll()

        if case .tabs(_, _, let activeID) = controller.root {
            #expect(activeID == b.id)
        } else {
            Issue.record("controller root is not a tabs leaf")
        }

        // After recompose, the active tab's content view should have updated.
        // We verify this loosely by counting nodes — both tabs are rendered as
        // buttons, so structure should still hold.
        let leafAfter = firstNonWrapper(tree.root!)
        #expect(leafAfter.children.count == 2)
        _ = graph
    } }

    @Test("DockContainer applies default horizontal inset and allows opt-out")
    func defaultHorizontalInset() { GlobalTestLock.locked {
        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "explorer", title: "Explorer")
        let controller = DockController(root: .tabs([tab]))

        let defaultTree = NodeTree()
        let defaultGraph = ViewGraph(tree: defaultTree, recomposer: Recomposer())
        defaultGraph.install(root: DockContainer(controller: controller, content: makeContent()))
        defaultGraph.computeLayout(width: 200, height: 120)

        let insetLeaf = firstTabsLeafHost(defaultTree.root!) ?? firstNonWrapper(defaultTree.root!)
        let insetFrame = absoluteFrame(of: insetLeaf)
        #expect(abs(Float(insetFrame.minX) - 8) < 0.5)
        #expect(abs(Float(insetFrame.width) - 184) < 0.5)

        let zeroTree = NodeTree()
        let zeroGraph = ViewGraph(tree: zeroTree, recomposer: Recomposer())
        zeroGraph.install(root: DockContainer(controller: controller,
                                              horizontalInset: 0,
                                              content: makeContent()))
        zeroGraph.computeLayout(width: 200, height: 120)

        let zeroLeaf = firstTabsLeafHost(zeroTree.root!) ?? firstNonWrapper(zeroTree.root!)
        let zeroFrame = absoluteFrame(of: zeroLeaf)
        #expect(abs(Float(zeroFrame.minX)) < 0.5)
        #expect(abs(Float(zeroFrame.width) - 200) < 0.5)
        _ = defaultGraph
        _ = zeroGraph
    } }

    // MARK: - Helpers

    private func firstNonWrapper(_ root: Node) -> Node {
        // ViewGraph mounts under root → wrapper chain. Walk into the first
        // child that has `> 1` child (the leaf/split Box).
        var n: Node = root
        while n.children.count == 1 {
            n = n.children[0]
        }
        return n
    }

    private func firstTabsLeafHost(_ node: Node) -> Node? {
        if node.attachments[_DockTabsLeafHost.kTabsLeafMarker] != nil {
            return node
        }
        for child in node.children {
            if let found = firstTabsLeafHost(child) { return found }
        }
        return nil
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

    private func findFirstHitTestable(_ node: Node) -> Node? {
        if node.isHitTestable { return node }
        for c in node.children {
            if let f = findFirstHitTestable(c) { return f }
        }
        return nil
    }

    private func collectHitTestable(_ node: Node) -> [Node] {
        var out: [Node] = []
        if node.isHitTestable { out.append(node) }
        for c in node.children {
            out.append(contentsOf: collectHitTestable(c))
        }
        return out
    }

    private func rootLeafID(of controller: DockController) -> DockNodeID {
        if case .tabs(let id, _, _) = controller.root { return id }
        Issue.record("expected a tabs leaf at root")
        return DockNodeID()
    }
}
