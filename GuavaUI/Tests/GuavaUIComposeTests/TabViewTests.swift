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
    private struct CountPanel: View {
        @State private var count = 0
        var body: some View { Button("Count \(count)") { count += 1 }.accessibilityLabel("Count \(count)") }
    }
    private final class SwitchingTabs: View {
        @State var selection = 0
        var body: some View {
            TabView(selection: $selection, tabs: [
                TabItem("First", id: 0) { CountPanel() },
                TabItem("Second", id: 1) { CountPanel() }
            ]).frame(width: 390, height: 220)
        }
    }

    @Test("Different tabs with the same panel type keep independent mounted state")
    func switchingSamePanelType() throws { try GlobalTestLock.locked {
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let fixture = SwitchingTabs(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: fixture)
        defer { graph.install(root: EmptyView()) }
        func settle() { for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: 390, height: 220) } }
        func counter(_ node: Node?) -> Node? {
            guard let node else { return nil }
            if node.isFocusable && node.accessibility?.label.hasPrefix("Count ") == true { return node }
            return node.children.lazy.compactMap(counter).first
        }
        settle()
        let first = try #require(counter(graph.tree.root))
        first.accessibilityActions.activate?(); settle()
        #expect(first.accessibility?.label == "Count 1")
        fixture.selection = 1; settle()
        let second = try #require(counter(graph.tree.root))
        #expect(second !== first && second.accessibility?.label == "Count 0")
        fixture.selection = 0; settle()
        let remounted = try #require(counter(graph.tree.root))
        #expect(remounted !== second && remounted !== first && remounted.accessibility?.label == "Count 0")
    } }

    @Test("Initial render shows only the selected tab's content")
    func showsActiveContent() { GlobalTestLock.locked {
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
    } }

    @Test("Different initial selection picks the matching content")
    func picksMatchingContent() { GlobalTestLock.locked {
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
    } }

    @Test("Selection that misses every tab renders no tab content")
    func missingSelectionRendersNothing() { GlobalTestLock.locked {
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
    } }
}
