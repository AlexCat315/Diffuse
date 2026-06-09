import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

/// Phase 4 acceptance: the Node tree and its Render / Input mirrors stay in
/// lockstep across add / remove / reorder, because the reconciler is the single
/// path that syncs them (坏味 #2). After the convergence, `Node.reorderChildren`
/// reorders only the source of truth; the mirrors are rebuilt solely by
/// `RenderTree.reconcileChildren` / `InputScene.reconcileChildren`. This stress
/// test permutes, removes, and re-inserts keyed children and asserts the three
/// trees never drift.
@Suite("Four-tree consistency (Phase 4)")
struct FourTreeConsistencyTests {

    private struct _Leaf: _PrimitiveView {
        let tag: Int
        func _makeNode() -> Node { Node() }
        func _updateNode(_ node: Node) { node.attachments["tag"] = tag }
        func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
        func _updateLayout(_ layout: LayoutNode) { layout.width = 10; layout.height = 10 }
    }

    /// A container with its own LayoutNode and no static children — the test
    /// drives its children directly through `reconcileChildren`.
    private struct _Container: _PrimitiveView {
        func _makeNode() -> Node { Node() }
        func _updateNode(_ node: Node) {}
        func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
        func _updateLayout(_ layout: LayoutNode) {}
        var _children: [any View] { [] }
    }

    private func leaves(_ ids: [Int]) -> [any View] {
        ids.map { _Leaf(tag: $0).id(AnyHashable($0)) as any View }
    }

    /// Recursively assert every node has both mirrors and that the mirror child
    /// lists are exactly the Node child list (same objects, same order).
    private func assertConsistent(_ node: Node, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(node.renderObject != nil, "missing RenderObject", sourceLocation: sourceLocation)
        #expect(node.inputNode != nil, "missing InputNode", sourceLocation: sourceLocation)

        if let ro = node.renderObject {
            let renderChildNodes = ro.children.compactMap { $0.node }
            #expect(renderChildNodes.count == node.children.count,
                    "render child count drift", sourceLocation: sourceLocation)
            #expect(renderChildNodes.elementsEqual(node.children, by: { $0 === $1 }),
                    "render child order drift", sourceLocation: sourceLocation)
        }
        if let inp = node.inputNode {
            let inputChildNodes = inp.children.compactMap { $0.node }
            #expect(inputChildNodes.count == node.children.count,
                    "input child count drift", sourceLocation: sourceLocation)
            #expect(inputChildNodes.elementsEqual(node.children, by: { $0 === $1 }),
                    "input child order drift", sourceLocation: sourceLocation)
        }
        for child in node.children { assertConsistent(child, sourceLocation: sourceLocation) }
    }

    private func reconcile(_ graph: ViewGraph, anchor: Node, to ids: [Int]) {
        graph.reconcileChildren(parent: anchor,
                                layoutParent: graph.layoutNode(for: anchor),
                                newViews: leaves(ids))
        graph.computeLayout(width: 200, height: 400)
    }

    @Test("Mirrors stay consistent across reorder / remove / insert churn")
    func mirrorsStayConsistentUnderChurn() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: _Container())
        let anchor = tree.root!.children.first!
        reconcile(graph, anchor: anchor, to: [0, 1, 2, 3, 4])
        assertConsistent(tree.root!)

        // A battery of structural mutations: reverse, rotate, drop middle,
        // re-insert, shuffle-ish permutations, shrink to one, grow back.
        let sequences: [[Int]] = [
            [4, 3, 2, 1, 0],          // full reverse
            [1, 2, 3, 4, 0],          // rotate
            [1, 3, 0, 4],             // drop "2", reorder
            [3, 1, 4, 0, 2, 5],       // re-insert "2", add new "5"
            [5, 4, 3, 2, 1, 0],       // reverse incl. new
            [2],                      // collapse to one
            [],                       // empty
            [7, 8, 9],                // all-new set
            [9, 7, 8],                // reorder new set
        ]
        for ids in sequences {
            reconcile(graph, anchor: anchor, to: ids)
            assertConsistent(tree.root!)

            // The reconciled child tags match the requested order exactly.
            let leafTags = anchor.children.compactMap { $0.attachments["tag"] as? Int }
            #expect(leafTags == ids, "leaf order \(leafTags) != requested \(ids)")
        }
    }

    @Test("Hit-test order matches paint order after a reorder")
    func hitAndPaintOrderAgreeAfterReorder() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: _Container())
        let anchor = tree.root!.children.first!
        reconcile(graph, anchor: anchor, to: [0, 1, 2])

        reconcile(graph, anchor: anchor, to: [2, 0, 1])
        assertConsistent(tree.root!)

        // Node tree, render mirror and input mirror present the leaves in the
        // identical sequence — so paint order (render array) and hit-test order
        // (input array, then z within it) are computed off the same ordering.
        let nodeTags = anchor.children.compactMap { $0.attachments["tag"] as? Int }
        let renderTags = anchor.renderObject!.children
            .compactMap { $0.node?.attachments["tag"] as? Int }
        let inputTags = anchor.inputNode!.children
            .compactMap { $0.node?.attachments["tag"] as? Int }
        #expect(nodeTags == [2, 0, 1])
        #expect(renderTags == nodeTags)
        #expect(inputTags == nodeTags)
    }
}
