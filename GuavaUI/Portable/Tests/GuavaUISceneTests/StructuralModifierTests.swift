import GuavaUIComposeCore
import GuavaUIScene
import Testing

@Suite("Modified structural view identity", .serialized)
@MainActor
struct StructuralModifierTests {
    private struct Counter: View {
        let name: String
        @State private var count = 0
        var body: some View { Probe(name: name, count: count) { count += 1 } }
    }
    private struct Probe: _PrimitiveView {
        let name: String
        let count: Int
        let action: () -> Void
        func _makeNode() -> Node { Node() }
        func _updateNode(_ node: Node) {
            node.attachments["probe-name"] = name
            node.attachments["probe-count"] = count
            node.accessibilityActions = AccessibilityActions()
            node.accessibilityActions.activate = action
        }
    }
    private final class ConditionalHarness: View {
        @State var revision = 0
        @State var shown = true
        @ViewBuilder private var content: some View {
            if shown { Counter(name: "counter") }
        }
        var body: some View { content.debugName("conditional-\(revision)") }
    }
    private final class ArrayHarness: View {
        @State var names = ["a", "b"]
        @State var revision = 0
        var body: some View {
            names.map { Counter(name: $0).id($0) }.debugName("array-\(revision)")
        }
    }
    private func probe(_ name: String, in node: Node?) -> Node? {
        guard let node else { return nil }
        if node.attachments["probe-name"] as? String == name { return node }
        return node.children.lazy.compactMap { probe(name, in: $0) }.first
    }
    @Test("Updating a modifier on an unchanged conditional preserves its child scope and local state")
    func conditional() throws {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let harness = ConditionalHarness()
        graph.install(root: harness)
        defer { graph.install(root: EmptyView()) }
        let node = try #require(probe("counter", in: graph.tree.root))
        let id = node.id
        node.accessibilityActions.activate?()
        graph.recomposer.commitAll()
        for revision in 1...4 {
            harness.revision = revision
            graph.recomposer.commitAll()
            #expect(probe("counter", in: graph.tree.root)?.id == id)
            #expect(probe("counter", in: graph.tree.root)?.attachments["probe-count"] as? Int == 1)
        }
        harness.shown = false
        graph.recomposer.commitAll()
        #expect(probe("counter", in: graph.tree.root) == nil)
        harness.shown = true
        graph.recomposer.commitAll()
        let restoredCount = probe("counter", in: graph.tree.root)?.attachments["probe-count"] as? Int
        #expect(restoredCount == 0)
    }
    @Test("Modified arrays preserve keyed child state through updates, reordering and insertion")
    func arrays() throws {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let harness = ArrayHarness()
        graph.install(root: harness)
        defer { graph.install(root: EmptyView()) }
        let node = try #require(probe("a", in: graph.tree.root))
        let id = node.id
        node.accessibilityActions.activate?()
        graph.recomposer.commitAll()
        for names in [["b", "a"], ["c", "a", "b"], ["a"]] {
            harness.names = names
            harness.revision += 1
            graph.recomposer.commitAll()
            #expect(probe("a", in: graph.tree.root)?.id == id)
            #expect(probe("a", in: graph.tree.root)?.attachments["probe-count"] as? Int == 1)
        }
    }
}
