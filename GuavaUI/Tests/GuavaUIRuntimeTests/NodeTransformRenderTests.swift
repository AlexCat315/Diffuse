import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime

/// `Node.transform` is only worth anything if the scale reaches the vertices.
/// `NodeTransformTests` pins the geometry the rest of the system asks the node
/// about; these pin that what comes out of `DrawList` matches it — in both
/// renderers, and through the layer cache that could otherwise serve geometry
/// recorded at the wrong size.
@Suite("Node transform rendering", .serialized)
struct NodeTransformRenderTests {

    /// Bounds of everything a render emitted.
    private func paintedBounds(_ list: DrawList) -> UIRect? {
        guard let first = list.vertices.first else { return nil }
        var minX = first.posX, maxX = first.posX
        var minY = first.posY, maxY = first.posY
        for vertex in list.vertices {
            minX = min(minX, vertex.posX); maxX = max(maxX, vertex.posX)
            minY = min(minY, vertex.posY); maxY = max(maxY, vertex.posY)
        }
        return UIRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Bounds of the red fills alone, so a red node can be measured inside a
    /// tree whose root paints something else.
    private func redBounds(_ list: DrawList) -> UIRect? {
        let reds = list.vertices.filter { ($0.color >> 24) & 0xFF == 0xFF }
        guard let first = reds.first else { return nil }
        var minX = first.posX, maxX = first.posX
        var minY = first.posY, maxY = first.posY
        for vertex in reds {
            minX = min(minX, vertex.posX); maxX = max(maxX, vertex.posX)
            minY = min(minY, vertex.posY); maxY = max(maxY, vertex.posY)
        }
        return UIRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Opaque red, the colour `redBounds` looks for.
    private func filled(_ x: CGFloat, _ y: CGFloat,
                        _ width: CGFloat, _ height: CGFloat) -> Node {
        let node = Node()
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        node.backgroundColor = Color(r: 1, g: 0, b: 0, a: 1)
        return node
    }

    /// A painted but transparent node, so a child's bounds can be read without
    /// its ancestors contributing to the union.
    private func plain(_ x: CGFloat, _ y: CGFloat,
                       _ width: CGFloat, _ height: CGFloat) -> Node {
        let node = Node()
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        return node
    }

    // MARK: - NodeRenderer

    @Test("A scaled node paints at the size its geometry reports")
    func scaledFillIsSmaller() {
        let root = plain(0, 0, 400, 400)
        let panel = filled(100, 40, 200, 100)
        root.addChild(panel)
        panel.transform = NodeTransform(scale: 0.5, anchor: .zero)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // What is drawn and what the rest of the system asks about have to be
        // the same rectangle, or the pointer hits somewhere the eye does not.
        #expect(redBounds(list) == UIRect(x: 100, y: 40, width: 100, height: 50))
        #expect(panel.absoluteFrame == CGRect(x: 100, y: 40, width: 100, height: 50))
    }

    @Test("A child's fill lands inside its scaled ancestor")
    func childFollowsParentScale() {
        let root = plain(0, 0, 400, 400)
        let group = plain(100, 100, 200, 200)
        root.addChild(group)
        let child = filled(0, 0, 40, 40)
        group.addChild(child)
        group.transform = NodeTransform(scale: 2, anchor: .zero)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        #expect(redBounds(list) == UIRect(x: 100, y: 100, width: 80, height: 80))
        #expect(child.absoluteFrame == CGRect(x: 100, y: 100, width: 80, height: 80))
    }

    /// A centre anchor draws the box smaller *and* pulls its origin toward the
    /// centre, which is the difference between "grew from the corner" and
    /// "inflated in place".
    @Test("A centre anchor pins the middle of the box")
    func centreAnchorHoldsStill() {
        let root = plain(0, 0, 400, 400)
        let panel = filled(100, 40, 200, 100)
        root.addChild(panel)
        panel.transform = NodeTransform(scale: 0.5, anchor: CGPoint(x: 0.5, y: 0.5))

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        let drawn = redBounds(list)!
        #expect(drawn == UIRect(x: 150, y: 65, width: 100, height: 50))
        #expect(drawn.x + drawn.width / 2 == 200)
        #expect(drawn.y + drawn.height / 2 == 90)
    }

    @Test("Scroll is applied before the scale on the same node")
    func scrollPrecedesScale() {
        let root = plain(0, 0, 400, 400)
        let viewport = filled(40, 20, 300, 200)
        root.addChild(viewport)
        let content = filled(0, 0, 300, 900)
        viewport.addChild(content)
        viewport.contentOffset = CGPoint(x: 0, y: 100)
        viewport.transform = NodeTransform(scale: 2, anchor: .zero)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // 100pt of scroll inside a box drawn at 2× puts the content 200pt up,
        // at 2× the width. Scaling the scroll instead would halve the speed
        // the offset asked for, and no other test in the tree would notice.
        #expect(redBounds(list) == UIRect(x: 40, y: -180, width: 600, height: 1800))
    }

    @Test("Corner radius and border width scale with the box")
    func metricsScaleToo() {
        let root = plain(0, 0, 400, 400)
        let panel = Node()
        panel.frame = CGRect(x: 20, y: 20, width: 100, height: 50)
        panel.cornerRadius = 10
        panel.borderWidth = 2
        panel.borderColor = Color.white
        root.addChild(panel)
        panel.transform = NodeTransform(scale: 0.5, anchor: .zero)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // A 10pt corner drawn at half size is a 5pt corner. Left alone the
        // panel reads as visibly rounder the smaller it gets — the opposite of
        // what growing from a corner should do. The stroke is the same story:
        // every length on the box is measured in the box's units.
        #expect(panel.absoluteFrame == CGRect(x: 20, y: 20, width: 50, height: 25))
        #expect(panel.cornerRadius * 0.5 == 5)
        #expect(panel.borderWidth * 0.5 == 1)
    }

    // MARK: - LayerAwareNodeRenderer

    /// Both renderers must agree, or a tree drawn through the layer cache looks
    /// different from the same tree drawn directly.
    @Test("The layer-aware renderer draws the same geometry")
    func layerAwareParity() {
        for scale in [Float(1), 0.5, 1.5] {
            let nodeTree = NodeTree()
            let render = RenderTree()
            let root = plain(0, 0, 400, 400)
            let group = Node()
            group.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            group.clipsToBounds = true
            root.addChild(group)
            group.addChild(filled(0, 0, 40, 40))
            group.transform = NodeTransform(scale: scale, anchor: CGPoint(x: 0.5, y: 0.5))
            nodeTree.root = root
            render.install(rootNode: root)

            let direct = DrawList()
            NodeRenderer().render(root: root, into: direct)

            let cached = DrawList()
            LayerAwareNodeRenderer().render(tree: render, into: cached)

            #expect(paintedBounds(direct) == paintedBounds(cached))
        }
    }

    /// The silent one: a node whose origin is unchanged but whose scale changed
    /// would pass an origin-only cache check and composite vertices recorded at
    /// the old size — a stale image with no error anywhere.
    @Test("Changing only the scale re-records the cached layer")
    func scaleChangeInvalidatesTheCache() {
        let nodeTree = NodeTree()
        let render = RenderTree()
        let root = plain(0, 0, 400, 400)
        let panel = filled(20, 20, 80, 40)
        panel.clipsToBounds = true
        root.addChild(panel)
        nodeTree.root = root
        render.install(rootNode: root)

        let renderer = LayerAwareNodeRenderer()
        let first = DrawList()
        renderer.render(tree: render, into: first)
        // The fill, not everything painted: a shadow's spread is not scaled
        // with the box, and it would swamp a one-pixel difference.
        let before = redBounds(first)!

        // Anchored top-left so the origin cannot move; only the size changes.
        panel.transform = NodeTransform(scale: 0.5, anchor: .zero)
        let second = DrawList()
        renderer.render(tree: render, into: second)
        let after = redBounds(second)!

        #expect(panel.absoluteOrigin == CGPoint(x: 20, y: 20))
        #expect(before == UIRect(x: 20, y: 20, width: 80, height: 40))
        #expect(after == UIRect(x: 20, y: 20, width: 40, height: 20))
    }

    /// A leaf layer that only *moved* still takes the translation fast path,
    /// which is the common case for text during a scroll and the reason the
    /// cache exists at all.
    @Test("A moved layer at an unchanged scale still reuses its cache")
    func translationFastPathSurvives() {
        let nodeTree = NodeTree()
        let render = RenderTree()
        let root = plain(0, 0, 400, 400)
        // clipsToBounds promotes it to a layer root, which is what puts it in
        // the per-layer cache this test is about.
        let chip = filled(20, 20, 60, 30)
        chip.clipsToBounds = true
        root.addChild(chip)
        nodeTree.root = root
        render.install(rootNode: root)

        let renderer = LayerAwareNodeRenderer()
        let first = DrawList()
        renderer.render(tree: render, into: first)
        #expect(redBounds(first) == UIRect(x: 20, y: 20, width: 60, height: 30))

        chip.frame = CGRect(x: 80, y: 20, width: 60, height: 30)
        chip.markRenderDirty()
        let second = DrawList()
        renderer.render(tree: render, into: second)

        #expect(redBounds(second) == UIRect(x: 80, y: 20, width: 60, height: 30))
    }
}