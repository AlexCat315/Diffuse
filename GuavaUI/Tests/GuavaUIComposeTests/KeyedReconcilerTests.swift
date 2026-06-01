import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

// MARK: - Test primitive that records identity-stable side data

/// `_TaggedNode` mirrors `_DebugNode` but carries a payload the test
/// installs into `Node.attachments` so we can prove the same node reused
/// across reconciles also retains its primitive-owned state.
struct _TaggedNode: _PrimitiveView {
    let payload: String

    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) {
        // Each materialisation stamps the current payload, but any value
        // already stored under "_initial" is left intact — we use that to
        // detect whether the node was reused or freshly created.
        if node.attachments["_initial"] == nil {
            node.attachments["_initial"] = payload
        }
        node.attachments["_latest"] = payload
    }
}

@Suite("Phase 2 keyed reconciler")
struct KeyedReconcilerTests {

    private func install<V: View>(_ view: V) -> (NodeTree, ViewGraph) {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: view)
        return (tree, graph)
    }

    @Test(".id(_:) stamps the key onto the produced node")
    func idStampsKey() {
        let (tree, _) = install(_TaggedNode(payload: "a").id("first"))
        let n = tree.root?.children.first
        #expect(n?.key == AnyHashable("first"))
        #expect(n?.viewTag?.contains("_TaggedNode") == true)
    }

    @Test("Keyed children survive reorder with state intact")
    func keyedReorderPreservesState() {
        struct Initial: View {
            var body: some View {
                _TaggedNode(payload: "A").id("a")
                _TaggedNode(payload: "B").id("b")
                _TaggedNode(payload: "C").id("c")
            }
        }
        struct Reordered: View {
            var body: some View {
                _TaggedNode(payload: "C").id("c")
                _TaggedNode(payload: "A").id("a")
                _TaggedNode(payload: "B").id("b")
            }
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Initial())
        let anchor = tree.root!.children.first!
        let originalA = anchor.children[0]
        let originalB = anchor.children[1]
        let originalC = anchor.children[2]

        graph.reconcileChildren(parent: anchor,
                                layoutParent: graph.layoutNode(for: anchor),
                                newViews: [Reordered().body])

        #expect(anchor.children.count == 3)
        // Reused, in new order.
        #expect(anchor.children[0] === originalC)
        #expect(anchor.children[1] === originalA)
        #expect(anchor.children[2] === originalB)
        // State stamped on first materialise survives reorder.
        #expect(originalA.attachments["_initial"] as? String == "A")
        #expect(originalB.attachments["_initial"] as? String == "B")
        #expect(originalC.attachments["_initial"] as? String == "C")
    }

    @Test("Unkeyed siblings still match by sequential type position")
    func unkeyedSequentialMatching() {
        struct Initial: View {
            var body: some View {
                _TaggedNode(payload: "A")
                _TaggedNode(payload: "B")
            }
        }
        struct UpdatedPayloads: View {
            var body: some View {
                _TaggedNode(payload: "A2")
                _TaggedNode(payload: "B2")
            }
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Initial())
        let anchor = tree.root!.children.first!
        let originalA = anchor.children[0]
        let originalB = anchor.children[1]

        graph.reconcileChildren(parent: anchor,
                                layoutParent: graph.layoutNode(for: anchor),
                                newViews: [UpdatedPayloads().body])

        #expect(anchor.children[0] === originalA)
        #expect(anchor.children[1] === originalB)
        // Same identity, but `_latest` updated to the new payload.
        #expect(originalA.attachments["_latest"] as? String == "A2")
        #expect(originalB.attachments["_latest"] as? String == "B2")
    }

    @Test("Removed keyed siblings are torn down; remaining ones survive")
    func teardownDropsRemovedKeyedChildren() {
        struct Initial: View {
            var body: some View {
                _TaggedNode(payload: "A").id("a")
                _TaggedNode(payload: "B").id("b")
                _TaggedNode(payload: "C").id("c")
            }
        }
        struct Trimmed: View {
            var body: some View {
                _TaggedNode(payload: "A").id("a")
                _TaggedNode(payload: "C").id("c")
            }
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Initial())
        let anchor = tree.root!.children.first!
        let originalA = anchor.children[0]
        let originalC = anchor.children[2]

        graph.reconcileChildren(parent: anchor,
                                layoutParent: graph.layoutNode(for: anchor),
                                newViews: [Trimmed().body])

        #expect(anchor.children.count == 2)
        #expect(anchor.children[0] === originalA)
        #expect(anchor.children[1] === originalC)
    }

    @Test("Adding a new keyed sibling materialises a fresh node")
    func insertNewKeyedSibling() {
        struct Initial: View {
            var body: some View {
                _TaggedNode(payload: "A").id("a")
                _TaggedNode(payload: "B").id("b")
            }
        }
        struct WithInsert: View {
            var body: some View {
                _TaggedNode(payload: "A").id("a")
                _TaggedNode(payload: "X").id("x")
                _TaggedNode(payload: "B").id("b")
            }
        }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Initial())
        let anchor = tree.root!.children.first!
        let originalA = anchor.children[0]
        let originalB = anchor.children[1]

        graph.reconcileChildren(parent: anchor,
                                layoutParent: graph.layoutNode(for: anchor),
                                newViews: [WithInsert().body])

        #expect(anchor.children.count == 3)
        #expect(anchor.children[0] === originalA)
        #expect(anchor.children[1] !== originalA && anchor.children[1] !== originalB)
        #expect(anchor.children[1].key == AnyHashable("x"))
        #expect(anchor.children[2] === originalB)
    }

    @Test("ElementID is unique per Node instance")
    func elementIDUniqueness() {
        let a = Node()
        let b = Node()
        #expect(a.id != b.id)
    }
}
