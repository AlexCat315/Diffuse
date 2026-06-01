import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

/// Phase 4a foundation tests.
///
/// Verifies the RenderObject mirror is built, kept in sync across reconcile,
/// and classifies layer roots from Node properties (clip, opacity, shadow).
@Suite("Phase 4a RenderTree mirror")
struct RenderTreeMirrorTests {

    /// Simple primitive whose `_makeNode` accepts an externally-supplied
    /// configurator so individual tests can flip layer-root inputs without
    /// inventing a primitive per test.
    struct _LayerNode: _PrimitiveView {
        let configure: (Node) -> Void
        func _makeNode() -> Node {
            let n = Node()
            configure(n)
            return n
        }
        func _updateNode(_ node: Node) { configure(node) }
    }

    @Test("Install mirrors the entire Node tree, sets back-pointers, and counts the root")
    func installBuildsMirror() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: _LayerNode { _ in })

        let root = tree.root!
        let renderRoot = graph.renderTree.root
        #expect(renderRoot != nil)
        #expect(renderRoot?.node === root)
        #expect(root.renderObject === renderRoot)
        #expect(graph.renderTree.objectCount >= 1)
        #expect(renderRoot?.isLayerRoot == true) // root always
    }

    @Test("Plain primitive without clip/opacity/shadow is not a layer root")
    func nonLayerLeafIsNotALayerRoot() {
        struct Wrapper: View {
            var body: some View {
                _LayerNode { _ in }
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Wrapper())

        let leaf = tree.root!.children.first!.children.first!
        let leafObj = graph.renderTree.renderObject(for: leaf)!
        #expect(leafObj.isLayerRoot == false)
    }

    @Test("clipsToBounds promotes a node to layer root")
    func clipPromotesToLayerRoot() {
        struct Wrapper: View {
            var body: some View {
                _LayerNode { node in node.clipsToBounds = true }
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Wrapper())
        let leaf = tree.root!.children.first!.children.first!
        let obj = graph.renderTree.renderObject(for: leaf)!
        #expect(obj.isLayerRoot == true)
    }

    @Test("Sub-1.0 opacity promotes a node to layer root")
    func opacityPromotesToLayerRoot() {
        struct Wrapper: View {
            var body: some View {
                _LayerNode { node in node.opacity = 0.5 }
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Wrapper())
        let leaf = tree.root!.children.first!.children.first!
        let obj = graph.renderTree.renderObject(for: leaf)!
        #expect(obj.isLayerRoot == true)
    }

    @Test("Reconcile keeps RenderObjects for reused children")
    func reconcileReusesRenderObjects() {
        struct Initial: View {
            var body: some View {
                _LayerNode { _ in }.id("a")
                _LayerNode { _ in }.id("b")
            }
        }
        struct Reordered: View {
            var body: some View {
                _LayerNode { _ in }.id("b")
                _LayerNode { _ in }.id("a")
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Initial())
        let anchor = tree.root!.children.first!
        let originalA = anchor.children[0]
        let originalB = anchor.children[1]
        let renderA = graph.renderTree.renderObject(for: originalA)!
        let renderB = graph.renderTree.renderObject(for: originalB)!

        graph.reconcileChildren(parent: anchor,
                                layoutParent: graph.layoutNode(for: anchor),
                                newViews: [Reordered().body])

        // Same RenderObjects, in new order.
        #expect(graph.renderTree.renderObject(for: originalA) === renderA)
        #expect(graph.renderTree.renderObject(for: originalB) === renderB)
        let mirror = graph.renderTree.renderObject(for: anchor)!
        #expect(mirror.children.count == 2)
        #expect(mirror.children[0] === renderB)
        #expect(mirror.children[1] === renderA)
    }

    @Test("Tearing down a node drops its mirror")
    func tearDownClearsMirror() {
        struct Initial: View {
            var body: some View {
                _LayerNode { _ in }.id("a")
                _LayerNode { _ in }.id("b")
            }
        }
        struct Trimmed: View {
            var body: some View {
                _LayerNode { _ in }.id("a")
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Initial())
        let anchor = tree.root!.children.first!
        let bNode = anchor.children[1]
        #expect(graph.renderTree.renderObject(for: bNode) != nil)

        graph.reconcileChildren(parent: anchor,
                                layoutParent: graph.layoutNode(for: anchor),
                                newViews: [Trimmed().body])

        #expect(graph.renderTree.renderObject(for: bNode) == nil)
        let mirror = graph.renderTree.renderObject(for: anchor)!
        #expect(mirror.children.count == 1)
    }

    @Test("LayerInventory enumerates root + clipped descendants")
    func layerInventoryEnumeratesLayerRoots() {
        struct Wrapper: View {
            var body: some View {
                _LayerNode { _ in }                                           // not layer
                _LayerNode { node in node.clipsToBounds = true }              // layer
                _LayerNode { node in node.opacity = 0.5 }                     // layer
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Wrapper())

        let layers = graph.renderTree.layerRoots()
        // Root is always one layer; plus the two promoted children.
        #expect(layers.count == 3)
        #expect(layers.first === graph.renderTree.root)
    }
}
