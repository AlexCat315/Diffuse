import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

/// Phase 4 acceptance: the Node tree and its Render mirror stay in lockstep
/// across add / remove / reorder, because the reconciler is the single path
/// that syncs them (坏味 #2). After the convergence, `Node.reorderChildren`
/// reorders only the source of truth; the render mirror is rebuilt solely by
/// `RenderTree.reconcileChildren`. (Phase 7 removed the input mirror — hit
/// order now reads the live Node tree, so there is no input tree to assert.)
/// This stress test permutes, removes, and re-inserts keyed children and
/// asserts the two trees never drift.
@Suite("Tree consistency (Phase 4/7)")
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

    /// Recursively assert every node has a RenderObject mirror whose child list
    /// is exactly the Node child list (same objects, same order).
    private func assertConsistent(_ node: Node, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(node.renderObject != nil, "missing RenderObject", sourceLocation: sourceLocation)

        if let ro = node.renderObject {
            let renderChildNodes = ro.children.compactMap { $0.node }
            #expect(renderChildNodes.count == node.children.count,
                    "render child count drift", sourceLocation: sourceLocation)
            #expect(renderChildNodes.elementsEqual(node.children, by: { $0 === $1 }),
                    "render child order drift", sourceLocation: sourceLocation)
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

        // Node tree and render mirror present the leaves in the identical
        // sequence — so paint order (render array) and hit-test order (live
        // Node array, then z within it) are computed off the same ordering.
        let nodeTags = anchor.children.compactMap { $0.attachments["tag"] as? Int }
        let renderTags = anchor.renderObject!.children
            .compactMap { $0.node?.attachments["tag"] as? Int }
        #expect(nodeTags == [2, 0, 1])
        #expect(renderTags == nodeTags)
    }
}
