import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime
@testable import GuavaUICore

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

    @Test("Glyphs crossing a straight edge keep exact texture interpolation")
    func straightEdgeGlyph() {
        let list = DrawList()
        list.pushMask(UIRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 100), radius: 10))
        list.addGlyphQuad(x: 95, y: 40, width: 10, height: 10,
                          uvMinX: 0, uvMinY: 0, uvMaxX: 1, uvMaxY: 1,
                          color: red, textureID: .none)
        let visible = Set(list.indices).map { list.vertices[Int($0)] }
        #expect(!visible.isEmpty)
        #expect(visible.allSatisfy { $0.posX <= 100 && $0.posX >= 95 })
        let edge = visible.filter { abs($0.posX - 100) < 0.001 }
        #expect(!edge.isEmpty && edge.allSatisfy { abs($0.u - 0.5) < 0.001 })
        #expect(covers(97, 45, in: list) && !covers(103, 45, in: list))
    }

    @Test("Invisible geometry drops indices while retaining cache bounds")
    func invisibleGeometry() {
        let clip = UIRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 100), radius: 10)
        let outside = DrawList()
        outside.pushMask(clip)
        outside.addRect(UIRect(x: 150, y: 20, width: 10, height: 10), color: red)
        #expect(outside.indices.isEmpty && outside.batches.isEmpty)
        #expect(outside.vertices.count == 4)
        #expect(outside.vertices.map(\.posX).max() == 160)

        let cached = DrawList()
        for x in [Float(-30), 40, 130] {
            cached.addRect(UIRect(x: x, y: 40, width: 10, height: 10), color: red)
        }
        let frame = DrawList()
        frame.pushMask(clip)
        frame.append(cached)
        #expect(frame.indices.count == 6)
        #expect(frame.vertices.count == cached.vertices.count)
        #expect(covers(45, 45, in: frame))
        #expect(!covers(-25, 45, in: frame) && !covers(135, 45, in: frame))
    }

    @Test("Geometry already clipped to the same mask is reused without retriangulation")
    func preclippedGeometry() {
        let clip = UIClip(UIRect(x: 0, y: 0, width: 100, height: 100),
                          mask: UIRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 100), radius: 15))
        let cached = DrawList()
        cached.pushClip(clip)
        cached.addRect(clip.rect, color: red)
        cached.popClip(clip)
        let frame = DrawList()
        frame.pushClip(clip)
        frame.appendPreclipped(cached, clips: [clip])
        #expect(frame.vertices.count == cached.vertices.count)
        #expect(frame.vertices.map(\.posX) == cached.vertices.map(\.posX))
        #expect(frame.vertices.map(\.posY) == cached.vertices.map(\.posY))
        #expect(frame.indices == cached.indices)
        #expect(!covers(1, 1, in: frame) && covers(50, 3, in: frame))

        let constrained = DrawList()
        constrained.pushClip(clip)
        let extra = UIClip(UIRect(x: 40, y: 40, width: 20, height: 20),
                           mask: UIRoundedRect(UIRect(x: 40, y: 40, width: 20, height: 20), radius: 5))
        constrained.pushClip(extra)
        constrained.appendPreclipped(cached, clips: [clip])
        #expect(covers(50, 50, in: constrained))
        #expect(!covers(20, 20, in: constrained) && !covers(40.5, 40.5, in: constrained))
    }

    @Test("Nested rounded caches preserve coverage through recording and reuse")
    func nestedCacheCoverage() {
        let root = Node(), pane = Node(), inner = Node(), leaf = Node()
        root.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        pane.frame = root.frame; pane.clipsToBounds = true; pane.cornerRadius = 20
        inner.frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        inner.clipsToBounds = true; inner.cornerRadius = 15
        leaf.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        leaf.updateDraw(identity: "fill") { [red] list, origin in
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 100, height: 100), color: red)
        }
        root.addChild(pane); pane.addChild(inner); inner.addChild(leaf)
        let render = RenderTree(); render.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        var counts: [Int] = []
        for _ in 0..<6 {
            let frame = DrawList(); renderer.render(tree: render, into: frame)
            #expect(covers(60, 12, in: frame) && covers(60, 60, in: frame))
            #expect(!covers(11, 11, in: frame) && !covers(109, 109, in: frame))
            counts.append(frame.indices.count)
        }
        #expect(Set(counts).count == 1)
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

    @Test("A cached leaf recorded outside a rounded clip paints once its parent moves it into view")
    func leafMovedIntoRoundedClip() {
        // An inspector section header first laid out below its scrolling pane,
        // then pulled up when the sections above it settle. The mask dropped
        // every triangle while the label sat outside the pane, so reusing that
        // cache at the new position paints nothing.
        let root = Node(), pane = Node(), header = Node(), label = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        pane.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        pane.cornerRadius = 8; pane.clipsToBounds = true
        header.frame = CGRect(x: 0, y: 150, width: 200, height: 20)
        label.frame = CGRect(x: 20, y: 0, width: 60, height: 20)
        label.updateDraw(identity: "label") { [red] list, origin in
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 60, height: 20), color: red)
        }
        root.addChild(pane); pane.addChild(header); header.addChild(label)
        let tree = NodeTree(); tree.root = root
        let render = RenderTree(); render.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()

        let offscreen = DrawList(); renderer.render(tree: render, into: offscreen)
        #expect(!covers(50, 160, in: offscreen, color: red))

        header.frame.origin.y = 40
        let layered = DrawList(); renderer.render(tree: render, into: layered)
        let direct = DrawList(); NodeRenderer().render(root: root, into: direct)
        for list in [direct, layered] {
            #expect(covers(50, 50, in: list, color: red))
        }
    }
}
