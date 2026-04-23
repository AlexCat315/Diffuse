import Testing
import CoreGraphics
@testable import GuavaUIRuntime

@Suite("Phase 4b LayerAwareNodeRenderer", .serialized)
struct LayerAwareNodeRendererTests {

    /// Holder that keeps strong references to every Node alive for the
    /// duration of a test. `RenderObject.node` is weak, so a test that
    /// drops a Node also drops the corresponding RenderObject's binding.
    private final class Tree {
        let nodeTree = NodeTree()
        let render = RenderTree()
        let root = Node()
        let a = Node()
        let b = Node()

        init() {
            root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            nodeTree.root = root

            a.frame = CGRect(x: 10, y: 10, width: 100, height: 100)
            a.backgroundColor = Color(r: 1, g: 0, b: 0, a: 1)
            root.addChild(a)

            b.frame = CGRect(x: 5, y: 5, width: 50, height: 50)
            b.clipsToBounds = true                   // promotes to layer root
            b.backgroundColor = Color(r: 0, g: 1, b: 0, a: 1)
            a.addChild(b)

            render.install(rootNode: root)
        }
    }

    @Test("Output matches NodeRenderer for the same tree")
    func parityWithNodeRenderer() {
        let t = Tree()

        let referenceList = DrawList()
        NodeRenderer().render(root: t.root, into: referenceList)

        let layerList = DrawList()
        LayerAwareNodeRenderer().render(tree: t.render, into: layerList)

        #expect(layerList.vertices.count == referenceList.vertices.count)
        #expect(layerList.indices.count == referenceList.indices.count)
        #expect(layerList.vertices.first?.posX == referenceList.vertices.first?.posX)
        #expect(layerList.vertices.first?.posY == referenceList.vertices.first?.posY)
        #expect(layerList.vertices.last?.posX == referenceList.vertices.last?.posX)
        #expect(layerList.vertices.last?.posY == referenceList.vertices.last?.posY)
    }

    @Test("Second composite reuses the cached layer DrawList when nothing changed")
    func cacheReuse() {
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()

        let first = DrawList()
        renderer.render(tree: t.render, into: first)

        let leafObj = t.render.renderObject(for: t.b)!
        #expect(leafObj.isLayerRoot)
        #expect(leafObj.cacheInvalid == false)
        let cachedList = leafObj.cachedLayerList
        #expect(cachedList != nil)

        let second = DrawList()
        renderer.render(tree: t.render, into: second)

        #expect(leafObj.cachedLayerList === cachedList)
        #expect(second.vertices.count == first.vertices.count)
        #expect(second.indices.count == first.indices.count)
    }

    @Test("markRenderDirty on a non-layer descendant invalidates the enclosing layer")
    func dirtyBubblesToEnclosingLayer() {
        // Root is its own layer; child A is non-layer; leaf B is its own layer.
        // Mutating A (non-layer) invalidates ROOT (the nearest layer root
        // above A) but not leaf B (a separate layer).
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())

        let rootObj = t.render.root!
        let leafObj = t.render.renderObject(for: t.b)!
        #expect(rootObj.cacheInvalid == false)
        #expect(leafObj.cacheInvalid == false)

        t.a.backgroundColor = Color(r: 0, g: 0, b: 1, a: 1)

        #expect(rootObj.cacheInvalid == true)
        #expect(leafObj.cacheInvalid == false)
    }

    @Test("After invalidation, a new composite re-records the dirty layer")
    func reRecordsAfterInvalidation() {
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())

        let rootObj = t.render.root!
        let firstCache = rootObj.cachedLayerList
        #expect(firstCache != nil)

        t.root.backgroundColor = Color(r: 0.5, g: 0.5, b: 0.5, a: 1)
        #expect(rootObj.cacheInvalid == true)

        renderer.render(tree: t.render, into: DrawList())
        #expect(rootObj.cachedLayerList !== firstCache)
        #expect(rootObj.cacheInvalid == false)
    }

    @Test("Promoting a node to a layer via opacity refreshes its classification")
    func opacityPromotesAndInvalidatesClassification() {
        let t = Tree()
        let aObj = t.render.renderObject(for: t.a)!
        #expect(aObj.isLayerRoot == false)

        t.a.opacity = 0.5
        #expect(aObj.isLayerRoot == true)
    }
}
