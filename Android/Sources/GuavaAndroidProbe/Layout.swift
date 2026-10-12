import GuavaUIComposeCore

extension ProbeContext {
    func layout() throws -> String {
        let root = LayoutNode(), first = LayoutNode(), second = LayoutNode()
        root.flexDirection = .row
        first.width = 20; first.height = 12
        second.flexGrow = 1; second.height = 12
        root.addChild(first); root.addChild(second)
        let tree = Node(), a = Node(), b = Node()
        tree.addChild(a); tree.addChild(b)
        LayoutPass.run(rootLayoutNode: root, rootNode: tree, availableWidth: 64, availableHeight: 64)
        try require(a.frame.width == 20 && b.frame.minX == 20 && b.frame.width == 44, "Yoga layout mismatch")
        let nodes = NodeTree(); nodes.root = tree; nodes.flush()
        try require(!nodes.hasRenderUpdates, "scene invalidation did not reset")
        b.markRenderDirty()
        try require(nodes.hasRenderUpdates, "scene invalidation did not propagate")
        return "shared GuavaUI scene graph, Yoga layout and invalidation/reset verified"
    }
}
