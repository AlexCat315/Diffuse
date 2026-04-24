import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("DrawList")
struct DrawListTests {

    @Test("Color packs to little-endian rgba8")
    func colorPacking() {
        let c = Color(red: 0x12, green: 0x34, blue: 0x56, alpha: 0x78)
        #expect(c.rgba8 == 0x78563412)
    }

    @Test("addRect emits 4 vertices and 6 indices in one batch")
    func addRectGeometry() {
        let list = DrawList()
        list.addRect(UIRect(x: 10, y: 20, width: 30, height: 40), color: .white)

        #expect(list.vertices.count == 4)
        #expect(list.indices.count == 6)
        #expect(list.batches.count == 1)
        #expect(list.batches[0].textureID == .none)
        #expect(list.batches[0].indexCount == 6)
        #expect(list.batches[0].indexOffset == 0)

        // Vertices: top-left, top-right, bottom-right, bottom-left
        #expect(list.vertices[0].posX == 10 && list.vertices[0].posY == 20)
        #expect(list.vertices[2].posX == 40 && list.vertices[2].posY == 60)
        // Solid sentinel
        #expect(list.vertices[0].u == -1)
    }

    @Test("Two adjacent rects merge into a single batch")
    func mergeAdjacentBatches() {
        let list = DrawList()
        list.addRect(UIRect(x: 0, y: 0, width: 10, height: 10), color: .white)
        list.addRect(UIRect(x: 20, y: 0, width: 10, height: 10), color: .black)

        #expect(list.vertices.count == 8)
        #expect(list.indices.count == 12)
        #expect(list.batches.count == 1)
        #expect(list.batches[0].indexCount == 12)
    }

    @Test("Different textureID splits batches")
    func textureSplitsBatches() {
        let list = DrawList()
        list.addRect(UIRect(x: 0, y: 0, width: 10, height: 10), color: .white)
        list.addGlyphQuad(
            x: 20, y: 0, width: 10, height: 10,
            uvMinX: 0, uvMinY: 0, uvMaxX: 1, uvMaxY: 1,
            color: .white, textureID: 1
        )
        list.addRect(UIRect(x: 40, y: 0, width: 10, height: 10), color: .white)

        #expect(list.batches.count == 3)
        #expect(list.batches[0].textureID == .none)
        #expect(list.batches[1].textureID == 1)
        #expect(list.batches[2].textureID == .none)
    }

    @Test("pushClip / popClip nest correctly")
    func clipStack() {
        let list = DrawList()
        list.pushClip(UIRect(x: 0, y: 0, width: 100, height: 100))
        list.addRect(UIRect(x: 0, y: 0, width: 10, height: 10), color: .white)
        list.pushClip(UIRect(x: 10, y: 10, width: 50, height: 50))
        list.addRect(UIRect(x: 20, y: 20, width: 5, height: 5), color: .white)
        list.popClip()
        list.addRect(UIRect(x: 30, y: 30, width: 10, height: 10), color: .white)
        list.popClip()
        list.addRect(UIRect(x: 0, y: 0, width: 5, height: 5), color: .white)

        // 4 batches: outer-clip, inner-clip, outer-clip, no-clip
        #expect(list.batches.count == 4)
        #expect(list.batches[0].scissor == UIRect(x: 0, y: 0, width: 100, height: 100))
        #expect(list.batches[1].scissor == UIRect(x: 10, y: 10, width: 50, height: 50))
        #expect(list.batches[2].scissor == UIRect(x: 0, y: 0, width: 100, height: 100))
        #expect(list.batches[3].scissor == nil)
    }

    @Test("Nested clips intersect with parent")
    func clipIntersection() {
        let list = DrawList()
        list.pushClip(UIRect(x: 0, y: 0, width: 100, height: 100))
        list.pushClip(UIRect(x: 50, y: 50, width: 200, height: 200))
        // Intersection should be (50, 50) -> (100, 100), i.e. 50x50.
        let clip = list.currentClip
        #expect(clip == UIRect(x: 50, y: 50, width: 50, height: 50))
    }

    @Test("Rounded rect emits anti-aliased centre quads, edges, and corner fans")
    func roundedRectGeometry() {
        let list = DrawList()
        list.addRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 60), radius: 10, color: .white)

        let expected = roundedRectGeometryCounts(radii: [11, 12, 10])
        #expect(list.vertices.count == expected.vertices)
        #expect(list.indices.count == expected.indices)
        // All in one batch (same textureID/scissor).
        #expect(list.batches.count == 1)
        #expect(list.batches[0].indexCount == UInt32(expected.indices))

        #expect(list.vertices.contains { $0.color == Color.white.rgba8 })
        #expect(list.vertices.contains { $0.color == Color.white.multipliedAlpha(0.22).rgba8 })
        #expect(list.vertices.contains { $0.color == Color.white.multipliedAlpha(0.08).rgba8 })
    }

    @Test("addText produces glyph quads with atlas UVs")
    func addTextGeometry() {
        let atlas = FontAtlas()
        atlas.loadFont(path: "/System/Library/Fonts/Supplemental/Arial.ttf", size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let shaped = shaper.shape(text: "Hi")
        let result = TextLayout.layout(
            shapedGlyphs: shaped, text: "Hi", atlas: atlas, lineHeight: 20
        )

        let list = DrawList()
        list.addText(result,
                     origin: (x: 0, y: 0),
                     color: .white,
                     textureID: 7,
                     atlas: atlas)

        // 2 visible glyphs → 8 vertices, 12 indices, 1 batch with textureID=7.
        #expect(list.vertices.count == 8)
        #expect(list.indices.count == 12)
        #expect(list.batches.count == 1)
        #expect(list.batches[0].textureID == 7)

        // First-glyph UV must match the atlas-rasterised glyph for 'H'.
        guard let hInfo = atlas.rasterizeCodepoint(UInt32(("H" as Character).asciiValue!)) else {
            Issue.record("expected 'H' to rasterise"); return
        }
        #expect(list.vertices[0].u == hInfo.uvMinX)
        #expect(list.vertices[0].v == hInfo.uvMinY)
    }

    @Test("addText snaps glyph quads to whole pixels")
    func addTextPixelSnap() {
        let atlas = FontAtlas()
        atlas.loadFont(path: "/System/Library/Fonts/Supplemental/Arial.ttf", size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let shaped = shaper.shape(text: "Hi")
        let result = TextLayout.layout(
            shapedGlyphs: shaped, text: "Hi", atlas: atlas, lineHeight: 20
        )
        guard let glyph = result.lines.first?.glyphs.first,
              let info = atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID) else {
            Issue.record("expected first glyph to exist")
            return
        }

        let origin: (x: Float, y: Float) = (0.35, 0.65)
        let rawX = origin.x + glyph.x + info.bearingX
        let rawY = origin.y + glyph.y - info.bearingY

        let list = DrawList()
        list.addText(result,
                 origin: origin,
                 color: .white,
                 textureID: 7,
                 atlas: atlas)

        #expect(list.vertices[0].posX == rawX.rounded())
        #expect(list.vertices[0].posY == rawY.rounded())
    }

    @Test("reset clears all CPU buffers")
    func resetClears() {
        let list = DrawList()
        list.addRect(UIRect(x: 0, y: 0, width: 10, height: 10), color: .white)
        list.reset()
        #expect(list.vertices.isEmpty)
        #expect(list.indices.isEmpty)
        #expect(list.batches.isEmpty)
        #expect(list.currentClip == nil)
    }

    private func roundedRectGeometryCounts(radii: [Float]) -> (vertices: Int, indices: Int) {
        radii.reduce(into: (vertices: 0, indices: 0)) { result, radius in
            let segments = cornerSegmentCount(radius: radius)
            result.vertices += 12 + 4 * (segments + 2)
            result.indices += 18 + 4 * segments * 3
        }
    }

    private func cornerSegmentCount(radius: Float) -> Int {
        let quarterArc = (.pi / 2) * max(0, radius)
        let estimated = Int(ceil(quarterArc / 0.8))
        return max(10, min(48, estimated))
    }
}
