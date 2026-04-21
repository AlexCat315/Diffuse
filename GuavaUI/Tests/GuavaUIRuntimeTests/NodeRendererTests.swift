import Testing
import CoreGraphics
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
