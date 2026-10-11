import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
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

    @Test("Retained geometry uses the current pixel density and refreshes when density changes")
    func pixelDensityParity() {
        let t = Tree()
        t.a.frame.origin = CGPoint(x: 10.26, y: 10.26)
        let renderer = LayerAwareNodeRenderer()
        for scale: Float in [1, 2, 2, 1] {
            let reference = DrawList()
            reference.pixelScale = scale
            NodeRenderer().render(root: t.root, into: reference)
            for _ in 0..<2 {
                let actual = DrawList()
                actual.pixelScale = scale
                renderer.render(tree: t.render, into: actual)
                #expect(actual.vertices.map { [$0.posX, $0.posY] } == reference.vertices.map { [$0.posX, $0.posY] })
            }
            #expect(t.render.root?.cachedLayerList?.pixelScale == scale)
        }
    }

    @Test("subtree fades preserve RGB and match cached and uncached rendering")
    func subtreeFadeParity() {
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())
        let cachedLeaf = t.render.renderObject(for: t.b)?.cachedLayerList
        t.a.subtreeOpacity = 0.5
        let faded = DrawList()
        renderer.render(tree: t.render, into: faded)
        let reference = DrawList()
        NodeRenderer().render(root: t.root, into: reference)
        #expect(faded.vertices.map(\.color) == reference.vertices.map(\.color))
        #expect(faded.vertices.allSatisfy { $0.color >> 24 == 128 })
        #expect(faded.vertices.first!.color & 0x00ff_ffff == 255)
        #expect(t.render.renderObject(for: t.b)?.cachedLayerList === cachedLeaf)
        t.a.subtreeOpacity = 1
        let restored = DrawList()
        renderer.render(tree: t.render, into: restored)
        #expect(restored.vertices.allSatisfy { $0.color >> 24 == 255 })
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

    @Test("Temporary backgrounds invalidate cached layers and restore latest authored values")
    func debugStylesInvalidateCachedLayer() {
        let t = Tree(), renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())
        t.b.debugBackgroundColor = .white
        var list = DrawList()
        renderer.render(tree: t.render, into: list)
        #expect(list.vertices.contains { $0.color == Color.white.rgba8 })
        t.b.backgroundColor = .black
        list = DrawList(); renderer.render(tree: t.render, into: list)
        #expect(list.vertices.contains { $0.color == Color.white.rgba8 })
        t.b.debugBackgroundColor = nil
        list = DrawList(); renderer.render(tree: t.render, into: list)
        #expect(list.vertices.contains { $0.color == Color.black.rgba8 })
        #expect(!list.vertices.contains { $0.color == Color.white.rgba8 })
    }

    @Test("paint changes invalidate retained caches even before dirty flags are flushed")
    func changesBetweenUnflushedPasses() {
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        // A failed surface acquisition can leave Node dirty flags set even
        // though composing the frame has already made the layer caches valid.
        renderer.render(tree: t.render, into: DrawList())
        renderer.render(tree: t.render, into: DrawList())
        #expect(t.b.renderDirty)
        #expect(t.render.root?.cachedLayerList != nil)
        #expect(t.render.root?.cacheInvalid == false)

        t.b.backgroundColor = Color(r: 0, g: 0, b: 1, a: 1)
        #expect(t.render.root?.cacheInvalid == true)
        #expect(t.render.renderObject(for: t.b)?.cacheInvalid == true)

        let actual = DrawList()
        let expected = DrawList()
        renderer.render(tree: t.render, into: actual)
        NodeRenderer().render(root: t.root, into: expected)
        #expect(actual.vertices.map(\.color) == expected.vertices.map(\.color))
    }

    @Test("a new painter identity is visible on retry without a successful flush")
    func painterChangesBetweenUnflushedPasses() {
        let t = Tree()
        t.b.updateDraw(identity: 1) { list, origin in
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 8, height: 8), color: .white)
        }
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())
        renderer.render(tree: t.render, into: DrawList())
        t.b.updateDraw(identity: 2) { list, origin in
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 12, height: 12), color: .black)
        }
        #expect(t.render.root?.cacheInvalid == true)
        let actual = DrawList()
        let expected = DrawList()
        renderer.render(tree: t.render, into: actual)
        NodeRenderer().render(root: t.root, into: expected)
        #expect(actual.vertices.map(\.posX) == expected.vertices.map(\.posX))
        #expect(actual.vertices.map(\.color) == expected.vertices.map(\.color))
    }

    @Test("Changed containers render directly before caching a stable frame")
    func containerCacheIsDeferredUntilStable() {
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        let rootObject = t.render.root!

        renderer.render(tree: t.render, into: DrawList())
        #expect(rootObject.cachedLayerList == nil)
        #expect(!rootObject.cacheInvalid)

        renderer.render(tree: t.render, into: DrawList())
        let stableCache = rootObject.cachedLayerList
        #expect(stableCache != nil)

        renderer.render(tree: t.render, into: DrawList())
        #expect(rootObject.cachedLayerList === stableCache)
    }

    @Test("markRenderDirty on a non-layer descendant invalidates the enclosing layer")
    func dirtyBubblesToEnclosingLayer() {
        // Root is its own layer; child A is non-layer; leaf B is its own layer.
        // Mutating A (non-layer) invalidates ROOT (the nearest layer root
        // above A) but not leaf B (a separate layer).
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())
        t.nodeTree.flush()

        let rootObj = t.render.root!
        let leafObj = t.render.renderObject(for: t.b)!
        #expect(rootObj.cacheInvalid == false)
        #expect(leafObj.cacheInvalid == false)

        t.a.backgroundColor = Color(r: 0, g: 0, b: 1, a: 1)

        #expect(rootObj.cacheInvalid == true)
        #expect(leafObj.cacheInvalid == false)
    }

    @Test("markRenderDirty on a nested layer invalidates ancestor layer caches")
    func dirtyNestedLayerInvalidatesAncestorLayerCaches() {
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())
        t.nodeTree.flush()

        let rootObj = t.render.root!
        let leafObj = t.render.renderObject(for: t.b)!
        #expect(rootObj.cacheInvalid == false)
        #expect(leafObj.cacheInvalid == false)

        t.b.contentOffset = CGPoint(x: 0, y: 12)

        #expect(leafObj.cacheInvalid == true)
        #expect(rootObj.cacheInvalid == true)
    }

    @Test("After invalidation, a new composite re-records the dirty layer")
    func reRecordsAfterInvalidation() {
        let t = Tree()
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())
        t.nodeTree.flush()

        let leafObj = t.render.renderObject(for: t.b)!
        let firstCache = leafObj.cachedLayerList
        #expect(firstCache != nil)

        t.b.backgroundColor = Color(r: 0.5, g: 0.5, b: 0.5, a: 1)
        #expect(leafObj.cacheInvalid == true)

        renderer.render(tree: t.render, into: DrawList())
        #expect(leafObj.cachedLayerList !== firstCache)
        #expect(leafObj.cacheInvalid == false)
    }

    @Test("Promoting a node to a layer via opacity refreshes its classification")
    func opacityPromotesAndInvalidatesClassification() {
        let t = Tree()
        let aObj = t.render.renderObject(for: t.a)!
        #expect(aObj.isLayerRoot == false)

        t.a.opacity = 0.5
        #expect(aObj.isLayerRoot == true)
    }

    @Test("Stable custom painter identity preserves its retained layer cache")
    func stablePainterIdentityPreservesCache() {
        let t = Tree()
        t.b.updateDraw(identity: "same") { list, origin in
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 4, height: 4),
                         color: .white)
        }
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())

        let object = t.render.renderObject(for: t.b)!
        #expect(object.isLayerRoot)
        let firstCache = object.cachedLayerList

        t.nodeTree.flush()
        t.b.updateDraw(identity: "same") { _, _ in }

        #expect(!t.root.renderDirty)
        #expect(!object.cacheInvalid)
        renderer.render(tree: t.render, into: DrawList())
        #expect(object.cachedLayerList === firstCache)
    }

    @Test("Changed custom painter identity invalidates only its retained path")
    func changedPainterIdentityInvalidates() {
        let t = Tree()
        t.a.updateDraw(identity: 1) { _, _ in }
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: t.render, into: DrawList())
        t.nodeTree.flush()

        let object = t.render.renderObject(for: t.a)!
        t.a.updateDraw(identity: 2) { _, _ in }

        #expect(object.cacheInvalid)
        #expect(t.render.root?.cacheInvalid == true)
        #expect(t.root.renderDirty)
    }

    @Test("Scrolling translates a stable leaf painter without rebuilding its cache")
    func scrollingTranslatesStableLeafPainter() {
        let nodeTree = NodeTree()
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        nodeTree.root = root

        let scroll = Node()
        scroll.frame = CGRect(x: 10, y: 10, width: 100, height: 80)
        scroll.clipsToBounds = true
        root.addChild(scroll)

        let leaf = Node()
        leaf.frame = CGRect(x: 4, y: 30, width: 40, height: 20)
        leaf.updateDraw(identity: "stable") { list, origin in
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 40, height: 20),
                         color: .white)
        }
        scroll.addChild(leaf)

        let renderTree = RenderTree()
        renderTree.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: renderTree, into: DrawList())
        nodeTree.flush()

        let leafObject = renderTree.renderObject(for: leaf)!
        let firstCache = leafObject.cachedLayerList
        scroll.contentOffset = CGPoint(x: 0, y: 12)

        let actual = DrawList()
        renderer.render(tree: renderTree, into: actual)
        let expected = DrawList()
        NodeRenderer().render(root: root, into: expected)

        #expect(leafObject.cachedLayerList === firstCache)
        #expect(actual.vertices.map(\.posX) == expected.vertices.map(\.posX))
        #expect(actual.vertices.map(\.posY) == expected.vertices.map(\.posY))
        #expect(actual.batches.map(\.scissor) == expected.batches.map(\.scissor))
    }

    @Test("Scrolling a painter-dense tree avoids rebuilding every leaf")
    func painterDenseScrollStress() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let scroll = Node()
        scroll.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        scroll.clipsToBounds = true
        root.addChild(scroll)

        var painterCalls = 0
        for row in 0..<300 {
            let leaf = Node()
            leaf.frame = CGRect(x: 12, y: row * 28, width: 900, height: 24)
            leaf.updateDraw(identity: row) { list, origin in
                painterCalls += 1
                for column in 0..<20 {
                    list.addGlyphQuad(
                        x: Float(origin.x) + Float(column * 10),
                        y: Float(origin.y),
                        width: 8,
                        height: 16,
                        uvMinX: 0,
                        uvMinY: 0,
                        uvMaxX: 1,
                        uvMaxY: 1,
                        color: .white,
                        textureID: 1
                    )
                }
            }
            scroll.addChild(leaf)
        }

        let renderTree = RenderTree()
        renderTree.install(rootNode: root)
        let retained = LayerAwareNodeRenderer()
        retained.render(tree: renderTree, into: DrawList())
        let callsAfterWarmup = painterCalls

        let retainedFrame = DrawList()
        for frame in 0..<30 {
            scroll.contentOffset = CGPoint(x: 0, y: frame * 3)
            retainedFrame.reset()
            retained.render(tree: renderTree, into: retainedFrame)
        }
        #expect(painterCalls == callsAfterWarmup)

        let legacyFrame = DrawList()
        let legacy = NodeRenderer()
        for frame in 0..<30 {
            scroll.contentOffset = CGPoint(x: 0, y: frame * 3)
            legacyFrame.reset()
            legacy.render(root: root, into: legacyFrame)
        }

        let visibleLegacy = legacyFrame.vertices.filter { $0.posY >= 0 && $0.posY <= 720 }
        let visibleRetained = retainedFrame.vertices.filter { $0.posY >= 0 && $0.posY <= 720 }
        #expect(visibleRetained.map(\.posX) == visibleLegacy.map(\.posX))
        #expect(visibleRetained.map(\.posY) == visibleLegacy.map(\.posY))
        #expect(retainedFrame.vertices.count < legacyFrame.vertices.count / 5)
        #expect(painterCalls == callsAfterWarmup + 300 * 30)
    }
    @Test("Initially offscreen leaves do not enter ancestor caches and reappear without repainting")
    func initiallyOffscreenLeaf() {
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.clipsToBounds = true
        let leaf = Node(); leaf.frame = CGRect(x: 0, y: 140, width: 20, height: 20)
        var paints = 0
        leaf.draw = { list, origin in
            paints += 1
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 20, height: 20), color: .white)
        }
        root.addChild(leaf)
        let tree = RenderTree(); tree.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for _ in 0..<3 {
            let frame = DrawList(); renderer.render(tree: tree, into: frame)
            #expect(frame.vertices.isEmpty)
        }
        #expect(paints == 1)
        root.contentOffset.y = 100
        let visible = DrawList(); renderer.render(tree: tree, into: visible)
        #expect(visible.vertices.count == 4)
        #expect(paints == 1)
    }

    @Test("Offscreen cached leaves are culled and reappear without losing overflow paint")
    func cachedLeafVisibility() {
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.clipsToBounds = true
        let leaf = Node(); leaf.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        var paints = 0
        leaf.draw = { list, origin in
            paints += 1
            // The painter intentionally extends beyond its Node.frame.
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 20, height: 60), color: .white)
        }
        root.addChild(leaf)
        let tree = RenderTree(); tree.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        renderer.render(tree: tree, into: DrawList())
        root.contentOffset.y = 100
        let outside = DrawList(); renderer.render(tree: tree, into: outside)
        #expect(outside.vertices.isEmpty)
        root.contentOffset.y = 30
        let overflow = DrawList(); renderer.render(tree: tree, into: overflow)
        #expect(!overflow.vertices.isEmpty) // frame is outside, actual painter is visible
        #expect(paints == 1)
        root.contentOffset.y = 0
        let returned = DrawList(); renderer.render(tree: tree, into: returned)
        #expect(returned.vertices.count == 4)
        #expect(paints == 1)
    }

    @Test("A clipped offscreen subtree avoids painter work until it enters the viewport")
    func clippedSubtreeVisibility() {
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let clipped = Node(); clipped.frame = CGRect(x: 0, y: 120, width: 100, height: 80)
        clipped.clipsToBounds = true
        let child = Node(); child.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        var paints = 0
        child.draw = { list, origin in
            paints += 1
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 50, height: 50), color: .white)
        }
        root.addChild(clipped); clipped.addChild(child)
        let tree = RenderTree(); tree.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        let first = DrawList(); renderer.render(tree: tree, into: first)
        #expect(paints == 0)
        #expect(first.vertices.isEmpty)
        root.contentOffset.y = 100
        let next = DrawList(); renderer.render(tree: tree, into: next)
        #expect(paints == 1)
        #expect(next.vertices.count == 4)
    }

}
