import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime

/// Rounded clipping containers must keep child geometry inside their corners
/// on every backend, since GPU scissors are rectangular.
@Suite("Rounded content clipping", .serialized)
struct RoundedClipTests {
    /// Whether any triangle with visible alpha covers `point`, optionally of one color.
    private func covers(_ x: Float, _ y: Float, in list: DrawList, color: Color? = nil) -> Bool {
        for start in stride(from: 0, to: list.indices.count, by: 3) {
            let v = (0..<3).map { list.vertices[Int(list.indices[start + $0])] }
            if let color, v[0].color & 0x00FF_FFFF != color.rgba8 & 0x00FF_FFFF { continue }
            let d = (v[1].posY - v[2].posY) * (v[0].posX - v[2].posX) + (v[2].posX - v[1].posX) * (v[0].posY - v[2].posY)
            guard abs(d) > 0.0001 else { continue }
            let a = ((v[1].posY - v[2].posY) * (x - v[2].posX) + (v[2].posX - v[1].posX) * (y - v[2].posY)) / d
            let b = ((v[2].posY - v[0].posY) * (x - v[2].posX) + (v[0].posX - v[2].posX) * (y - v[2].posY)) / d
            if min(a, b, 1 - a - b) >= -0.0001 && v[0].color >> 24 > 20 { return true }
        }
        return false
    }

    private let red = Color(r: 1, g: 0, b: 0, a: 1)

    @Test("A mask cuts the corners of emitted geometry and keeps its interior intact")
    func maskCutsCorners() {
        let list = DrawList()
        list.pushMask(UIRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 50), radius: 12))
        list.addRect(UIRect(x: 0, y: 0, width: 100, height: 50), color: red)
        list.addRect(UIRect(x: 20, y: 20, width: 10, height: 10), color: red)
        list.popMask()
        #expect(!covers(1, 1, in: list) && !covers(99, 49, in: list) && !covers(99, 1, in: list))
        #expect(covers(50, 25, in: list) && covers(50, 1, in: list) && covers(1, 25, in: list))
        #expect(covers(6, 6, in: list))  // inside the arc of a 12pt corner
        // The small interior rect passes through as its original two triangles.
        list.addRect(UIRect(x: 0, y: 0, width: 4, height: 4), color: red)
        #expect(covers(1, 1, in: list))
    }

    @Test("Clipping interpolates texture coordinates and colors along cut edges")
    func interpolation() {
        let list = DrawList()
        list.pushMask(UIRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 100), radius: 50))
        list.addRect(UIRect(x: 0, y: 0, width: 100, height: 100), color: red)
        for vertex in list.vertices.suffix(from: 4) {
            let dx = vertex.posX - 50, dy = vertex.posY - 50
            #expect((dx * dx + dy * dy).squareRoot() <= 50.01)
        }
    }

    @Test("Appended cached geometry is clipped by the destination's masks")
    func appendedGeometry() {
        let cached = DrawList()
        cached.addRect(UIRect(x: 0, y: 0, width: 80, height: 40), color: red)
        let frame = DrawList()
        frame.pushMask(UIRoundedRect(UIRect(x: 0, y: 0, width: 80, height: 40), radius: 10))
        frame.append(cached)
        #expect(!covers(1, 1, in: frame) && covers(40, 20, in: frame))
        #expect(frame.batches.reduce(0) { $0 + Int($1.indexCount) } == frame.indices.count)
    }

    @Test("A rounded clipping container keeps a full-size child fill inside its border in both renderers")
    func containerParity() {
        let root = Node(), card = Node(), chip = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        card.frame = CGRect(x: 10, y: 10, width: 120, height: 40)
        card.cornerRadius = 8; card.clipsToBounds = true
        card.borderColor = Color(r: 0, g: 0, b: 1, a: 1); card.borderWidth = 1
        chip.frame = CGRect(x: 0, y: 0, width: 30, height: 40)
        chip.backgroundColor = red
        root.addChild(card); card.addChild(chip)
        let tree = NodeTree(); tree.root = root
        let render = RenderTree(); render.install(rootNode: root)

        let direct = DrawList(); NodeRenderer().render(root: root, into: direct)
        let layered = DrawList(); LayerAwareNodeRenderer().render(tree: render, into: layered)
        for list in [direct, layered] {
            #expect(!covers(11, 11, in: list, color: red))          // outside the rounded corner
            #expect(!covers(10.5, 30, in: list, color: red))        // on the border, not under it
            #expect(covers(25, 30, in: list, color: red))           // ordinary content
            #expect(covers(16, 16, in: list, color: red))           // inside the arc
        }
    }
}
