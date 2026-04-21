import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("CompositionLocal")
struct CompositionLocalTests {

    // MARK: - Direct Node API

    @Test("Node.compositionValue falls back to defaultValue when no provider exists")
    func nodeFallsBackToDefault() {
        let local = CompositionLocal<Int>(defaultValue: 42)
        let node = Node()
        #expect(node.compositionValue(of: local) == 42)
    }

    @Test("Node.setCompositionValue stores per-node values")
    func nodeStoresValue() {
        let local = CompositionLocal<String>(defaultValue: "default")
        let node = Node()
        node.setCompositionValue(local, "hello")
        #expect(node.compositionValue(of: local) == "hello")
    }

    @Test("Lookup walks up the parent chain")
    func lookupWalksParents() {
        let local = CompositionLocal<Int>(defaultValue: -1)
        let root = Node()
        let mid = Node()
        let leaf = Node()
        root.addChild(mid)
        mid.addChild(leaf)
        root.setCompositionValue(local, 7)
        #expect(leaf.compositionValue(of: local) == 7)
        #expect(mid.compositionValue(of: local) == 7)
        #expect(root.compositionValue(of: local) == 7)
    }

    @Test("Nearest ancestor wins over a more distant one")
    func nearestAncestorWins() {
        let local = CompositionLocal<Int>(defaultValue: 0)
        let root = Node()
        let mid = Node()
        let leaf = Node()
        root.addChild(mid)
        mid.addChild(leaf)
        root.setCompositionValue(local, 1)
        mid.setCompositionValue(local, 2)
        #expect(leaf.compositionValue(of: local) == 2)
    }

    @Test("Distinct CompositionLocal declarations are isolated")
    func distinctLocalsAreIsolated() {
        let a = CompositionLocal<Int>(defaultValue: 0)
        let b = CompositionLocal<Int>(defaultValue: 0)
        let node = Node()
        node.setCompositionValue(a, 11)
        node.setCompositionValue(b, 22)
        #expect(node.compositionValue(of: a) == 11)
        #expect(node.compositionValue(of: b) == 22)
    }

    // MARK: - Compose-layer .compositionLocal modifier

    @Test("compositionLocal modifier writes onto the wrapper node")
    func modifierWritesOntoWrapper() {
        let local = CompositionLocal<Int>(defaultValue: 0)
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)

        graph.install(root: _DebugNode(label: "leaf").compositionLocal(local, 99))

        // tree.root → wrapper node (the _DebugNode primitive node carrying
        // the wrapper viewTag). The provider value lives on it.
        let wrapper = tree.root!.children.first!
        #expect(wrapper.compositionValue(of: local) == 99)
    }

    @Test("Descendants resolve the provider via parent walk")
    func descendantsResolveProvider() {
        let local = CompositionLocal<String>(defaultValue: "default")
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)

        struct ParentView: View {
            let inner: _DebugNode
            var body: some View { inner }
        }

        graph.install(root: ParentView(inner: _DebugNode(label: "x"))
            .compositionLocal(local, "themed"))

        // Walk to the deepest node and ensure the value is reachable.
        var cursor = tree.root!
        while let next = cursor.children.first {
            cursor = next
        }
        #expect(cursor.compositionValue(of: local) == "themed")
    }
}
