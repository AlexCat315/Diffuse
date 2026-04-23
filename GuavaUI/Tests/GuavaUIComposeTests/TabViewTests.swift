import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// A tiny primitive whose only job is to mark a node with a probe id so the
/// test can search for it in the rendered tree.
private struct ProbeView: _PrimitiveView {
    static let key = "__tabview_probe_id"
    let id: Int
    func _makeNode() -> Node {
        let n = Node()
        n.attachments[ProbeView.key] = id
        return n
    }
    func _updateNode(_ node: Node) {
        node.attachments[ProbeView.key] = id
    }
}

private func findProbe(_ root: Node, id: Int) -> Node? {
    if (root.attachments[ProbeView.key] as? Int) == id { return root }
    for c in root.children {
        if let n = findProbe(c, id: id) { return n }
    }
    return nil
}

@Suite("TabView selection")
struct TabViewTests {

    @Test("Initial render shows only the selected tab's content")
    func showsActiveContent() {
        var sel = 0
        let binding = Binding<Int>(get: { sel }, set: { sel = $0 })
        let tabs = [
            TabItem("A", id: 0) { ProbeView(id: 100) },
            TabItem("B", id: 1) { ProbeView(id: 200) }
        ]
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: TabView(selection: binding, tabs: tabs))

        #expect(findProbe(tree.root!, id: 100) != nil)
        #expect(findProbe(tree.root!, id: 200) == nil)
        _ = graph // keep alive
    }

    @Test("Different initial selection picks the matching content")
    func picksMatchingContent() {
        var sel = 1
        let binding = Binding<Int>(get: { sel }, set: { sel = $0 })
        let tabs = [
            TabItem("A", id: 0) { ProbeView(id: 100) },
            TabItem("B", id: 1) { ProbeView(id: 200) }
        ]
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: TabView(selection: binding, tabs: tabs))

        #expect(findProbe(tree.root!, id: 100) == nil)
        #expect(findProbe(tree.root!, id: 200) != nil)
        _ = graph
    }

    @Test("Selection that misses every tab renders no tab content")
    func missingSelectionRendersNothing() {
        var sel = 99
        let binding = Binding<Int>(get: { sel }, set: { sel = $0 })
        let tabs = [
            TabItem("A", id: 0) { ProbeView(id: 100) },
            TabItem("B", id: 1) { ProbeView(id: 200) }
        ]
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: TabView(selection: binding, tabs: tabs))

        #expect(findProbe(tree.root!, id: 100) == nil)
        #expect(findProbe(tree.root!, id: 200) == nil)
        _ = graph
    }
}
