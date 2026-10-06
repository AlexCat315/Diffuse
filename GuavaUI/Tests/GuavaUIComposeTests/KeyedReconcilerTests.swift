import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose
@testable import GuavaUIComposeCore

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
    func idStampsKey() { GlobalTestLock.locked {
        let (tree, _) = install(_TaggedNode(payload: "a").id("first"))
        let n = tree.root?.children.first
        #expect(n?.key == AnyHashable("first"))
        #expect(n?.viewTag?.contains("_TaggedNode") == true)
    } }

    @Test("Keyed children survive reorder with state intact")
    func keyedReorderPreservesState() { GlobalTestLock.locked {
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
    } }

    @Test("Unkeyed siblings still match by sequential type position")
    func unkeyedSequentialMatching() { GlobalTestLock.locked {
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
    } }

    @Test("Removed keyed siblings are torn down; remaining ones survive")
    func teardownDropsRemovedKeyedChildren() { GlobalTestLock.locked {
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
    } }

    @Test("Adding a new keyed sibling materialises a fresh node")
    func insertNewKeyedSibling() { GlobalTestLock.locked {
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
    } }

    @Test("ElementID is unique per Node instance")
    func elementIDUniqueness() { GlobalTestLock.locked {
        let a = Node()
        let b = Node()
        #expect(a.id != b.id)
    } }

    @Test("Keys before ordinary modifiers survive updates and reorder")
    func modifiedKeysPreserveNodes() { GlobalTestLock.locked {
        let (tree, graph) = install(_TaggedNode(payload: "A").id("a").frame(height: 30).flex())
        let parent = tree.root!
        let originalA = parent.children[0]
        let a = _TaggedNode(payload: "A2").id("a").frame(height: 30).flex()
        let b = _TaggedNode(payload: "B").id("b").frame(height: 30).flex()
        graph.reconcileChildren(parent: parent, layoutParent: graph.layoutRoot, newViews: [a, b])
        let originalB = parent.children[1]
        graph.reconcileChildren(parent: parent, layoutParent: graph.layoutRoot, newViews: [b, a])
        graph.reconcileChildren(parent: parent, layoutParent: graph.layoutRoot, newViews: [b, a])
        #expect(parent.children[0] === originalB)
        #expect(parent.children[1] === originalA)
        #expect(originalA.attachments["_initial"] as? String == "A")
        #expect(originalA.attachments["_latest"] as? String == "A2")
    } }

    @Test("Outermost key wins on materialisation and repeated updates")
    func outerKeySurvivesUpdates() { GlobalTestLock.locked {
        let view = _TaggedNode(payload: "A").id("inner").frame(height: 30).id("outer")
        let (tree, graph) = install(view)
        let original = tree.root!.children[0]
        for _ in 0..<3 {
            graph.reconcileChildren(parent: tree.root!, layoutParent: graph.layoutRoot, newViews: [view])
            #expect(tree.root!.children[0] === original)
            #expect(original.key == AnyHashable("outer"))
        }
    } }

    @Test("Scope and animation anchors keep child keys local")
    func anchorKeysRemainLocal() { GlobalTestLock.locked {
        let scoped = _TaggedNode(payload: "A").id("child").theme(.defaultDark).frame(height: 30)
        let animated = _TaggedNode(payload: "A").id("child").animation(nil, value: 0).frame(height: 30)
        let views: [any View] = [scoped, animated]
        for view in views {
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: AnyView(view))
            let original = tree.root!.children[0]
            #expect(original.key == nil)
            #expect(ViewGraph.slotKey(view) == nil)
            graph.reconcileChildren(parent: tree.root!, layoutParent: graph.layoutRoot, newViews: [view])
            #expect(tree.root!.children[0] === original)
            #expect(original.children[0].key == AnyHashable("child"))
        }
    } }
}
