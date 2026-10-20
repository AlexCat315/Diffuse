import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime

@Suite("NodeRenderer")
struct NodeRendererTests {

    @Test("Background fills emit one quad per node")
    func backgroundFillsEmitQuads() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        root.backgroundColor = Color.white

        let child = Node()
        child.frame = CGRect(x: 10, y: 20, width: 50, height: 30)
        child.backgroundColor = Color(r: 1, g: 0, b: 0)
        root.addChild(child)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // Two filled quads → 8 vertices, 12 indices.
        #expect(list.vertices.count == 8)
        #expect(list.indices.count == 12)
        // Both share textureID .none → merged into one batch.
        #expect(list.batches.count == 1)
        #expect(list.batches[0].textureID == .none)
    }

    @Test("A frosted node attaches its backdrop to its own fill")
    func backdropRidesOnTheFill() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        root.backgroundColor = Color.white

        let panel = Node()
        panel.frame = CGRect(x: 20, y: 20, width: 80, height: 40)
        panel.cornerRadius = 6
        panel.backdropBlur = 12
        panel.backgroundColor = Color(r: 1, g: 1, b: 1, a: 0.84)
        root.addChild(panel)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // The panel cannot merge into the container behind it: the blur has to
        // land between the two, which only a batch boundary can express.
        #expect(list.batches.count == 2)
        #expect(list.batches[0].backdrop == nil)
        // The backdrop covers the whole node, not just the fill, so the border
        // ring drawn over it stays crisp.
        #expect(list.batches[1].backdrop == UIBackdrop(
            rect: UIRect(x: 20, y: 20, width: 80, height: 40), cornerRadius: 6, blurRadius: 12))
    }

    @Test("A frosted panel's border is drawn in the backdrop batch, after the fill")
    func frostedBorderStaysOnTop() {
        for layered in [false, true] {
            let root = Node()
            root.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
            root.backgroundColor = Color(r: 0.2, g: 0.2, b: 0.2)
            let panel = Node()
            panel.frame = CGRect(x: 20, y: 20, width: 80, height: 40)
            panel.cornerRadius = 6
            panel.backdropBlur = 12
            panel.backgroundColor = Color(r: 1, g: 1, b: 1, a: 0.5)
            panel.borderColor = Color(r: 0, g: 0, b: 0, a: 0.1)
            panel.borderWidth = 1
            root.addChild(panel)
            let list = DrawList()
            if layered {
                let tree = RenderTree()
                tree.install(rootNode: root)
                LayerAwareNodeRenderer().render(tree: tree, into: list)
            }
            else { NodeRenderer().render(root: root, into: list) }
            let frosted = list.batches.firstIndex { $0.backdrop != nil }
            #expect(frosted != nil)
            // The ring's translucent black lands in the composited batch, so it
            // is painted over the frost rather than under it.
            let ring = list.vertices.indices.filter { list.vertices[$0].color == Color(r: 0, g: 0, b: 0, a: 0.1).rgba8 }
            let start = Int(list.batches[frosted!].indexOffset)
            let firstRingIndex = list.indices.firstIndex { ring.contains(Int($0)) }
            #expect(firstRingIndex.map { $0 >= start } == true)
        }
    }

    @Test("A backdrop with no fill leaves nothing behind")
    func backdropWithoutFillIsDropped() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.backdropBlur = 12

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)
        #expect(list.batches.isEmpty)
    }

    @Test("Child frames are translated by parent origin")
    func childFramesAccumulateOrigin() {
        let root = Node()
        root.frame = CGRect(x: 5, y: 7, width: 100, height: 100)

        let child = Node()
        child.frame = CGRect(x: 10, y: 10, width: 20, height: 20)
        child.backgroundColor = Color.white
        root.addChild(child)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // Child quad's first vertex must be at (root.x + child.x, root.y + child.y).
        #expect(list.vertices.first?.posX == 15)
        #expect(list.vertices.first?.posY == 17)
    }

    @Test("clipsToBounds pushes a scissor rect for the subtree")
    func clipsToBoundsPushesScissor() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.clipsToBounds = true

        let child = Node()
        child.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        child.backgroundColor = Color.white
        root.addChild(child)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        let scissor = list.batches.first?.scissor
        #expect(scissor == UIRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("Custom draw callback fires after background")
    func drawCallbackFires() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        root.backgroundColor = Color(r: 0, g: 0, b: 1)

        var observed: CGPoint?
        root.draw = { _, origin in
            observed = origin
        }

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        #expect(observed == CGPoint(x: 0, y: 0))
        // Background still emitted.
        #expect(list.vertices.count == 4)
    }

    @Test("opacity multiplies background alpha")
    func opacityMultipliesAlpha() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        root.backgroundColor = Color(r: 1, g: 0, b: 0, a: 1)
        root.opacity = 0.5

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // Decode the alpha byte from the packed color.
        let packed = list.vertices.first!.color
        let alphaByte = (packed >> 24) & 0xFF
        #expect(alphaByte >= 126 && alphaByte <= 129)  // ~127 ± 1
    }

    @Test("contentOffset translates children but not the parent's clip")
    func contentOffsetTranslatesChildren() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.clipsToBounds = true
        root.contentOffset = CGPoint(x: 0, y: 30)

        let child = Node()
        child.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        child.backgroundColor = Color.white
        root.addChild(child)

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // Clip stays at the root's frame.
        #expect(list.batches.first?.scissor == UIRect(x: 0, y: 0, width: 100, height: 100))
        // Child quad rendered at y = -contentOffset.y.
        #expect(list.vertices.first?.posY == -30)
    }

    @Test("cornerRadius switches the background fill to a rounded-rect path")
    func cornerRadiusEmitsRoundedRect() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.backgroundColor = Color.white
        root.cornerRadius = 12

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        // Plain rect emits 4 verts; rounded-rect decomposes into many more
        // (centre quad + edges + per-corner triangle fans).
        #expect(list.vertices.count > 4)
        #expect(list.batches.count == 1)
        #expect(list.batches[0].textureID == .none)
    }

    @Test("cornerRadius == 0 keeps the plain rect path")
    func cornerRadiusZeroIsPlain() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.backgroundColor = Color.white
        root.cornerRadius = 0

        let list = DrawList()
        NodeRenderer().render(root: root, into: list)

        #expect(list.vertices.count == 4)
    }
}
