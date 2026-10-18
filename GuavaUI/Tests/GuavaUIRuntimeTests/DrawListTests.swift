import Foundation
import Testing
@testable import GuavaUIRuntime

/// Cross-platform test font resolved from the host's system fonts
/// (see `systemTestFontPath()` in TextTests.swift).
private let drawListTestFontPath = systemTestFontPath()

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

    @Test("Lines emit an opaque core, transparent fringe and rounded caps")
    func lineCoverage() {
        let list = DrawList()
        list.pixelScale = 2
        list.addLine(fromX: 2, fromY: 3, toX: 42, toY: 23,
                     thickness: 2, color: .white)

        #expect(list.vertices.count > 4)
        #expect(list.indices.count > 6)
        #expect(list.indices.allSatisfy { $0 < list.vertices.count })
        #expect(list.vertices.contains { $0.color >> 24 == 0xFF })
        #expect(list.vertices.contains { $0.color >> 24 == 0 })
        #expect(list.batches.count == 1)
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

    @Test("A backdrop request rides on its own batch")
    func backdropStartsOwnBatch() {
        let list = DrawList()
        // The shadow behind a panel: solid colour, same texture, same scissor,
        // and exactly the kind of draw a frosted fill would otherwise merge
        // into — which would put the blur behind the shadow instead of the fill.
        list.addRect(UIRect(x: 0, y: 0, width: 40, height: 40), color: .black)
        list.beginBackdrop(UIBackdrop(rect: UIRect(x: 4, y: 4, width: 32, height: 32),
                                      cornerRadius: 6, blurRadius: 12))
        list.addRoundedRect(UIRect(x: 4, y: 4, width: 32, height: 32), radius: 6, color: .white)
        // And the request is consumed: the row after the fill merges as usual.
        list.addRect(UIRect(x: 4, y: 4, width: 32, height: 32), color: .white)

        #expect(list.batches.count == 2)
        #expect(list.batches[0].backdrop == nil)
        #expect(list.batches[0].indexCount == 6)
        let frosted = list.batches[1]
        #expect(frosted.backdrop == UIBackdrop(rect: UIRect(x: 4, y: 4, width: 32, height: 32),
                                               cornerRadius: 6, blurRadius: 12))
        #expect(frosted.indexOffset == 6)
        // The rounded fill plus the rect that follows it: one batch, as if no
        // request had ever been made.
        #expect(frosted.indexCount == UInt32(list.indices.count - 6))
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

    @Test("Rounded fill coverage stays within half a physical pixel and preserves source alpha")
    func roundedRectGeometry() {
        for scale: Float in [1, 1.5, 2, 3] {
            let list = DrawList()
            list.pixelScale = scale
            let tint = Color(red: 40, green: 90, blue: 180, alpha: 128)
            list.addRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 60), radius: 10, color: tint)
            #expect(list.batches.count == 1)
            #expect(list.batches[0].indexCount == UInt32(list.indices.count))
            #expect(list.indices.allSatisfy { $0 < list.vertices.count })
            #expect(list.vertices.allSatisfy { ($0.color >> 24) == 128 || ($0.color >> 24) == 0 })
            let left = list.vertices.map(\.posX).min()!
            let right = list.vertices.map(\.posX).max()!
            #expect(abs(left + 0.5 / scale) < 0.001)
            #expect(abs(right - 100 - 0.5 / scale) < 0.001)
            // No triangle interiors overlap: translucent fills must be painted
            // once, not made more opaque by the antialiasing implementation.
            let area = stride(from: 0, to: list.indices.count, by: 3).reduce(Float.zero) { sum, index in
                let a = list.vertices[Int(list.indices[index])]
                let b = list.vertices[Int(list.indices[index + 1])]
                let c = list.vertices[Int(list.indices[index + 2])]
                return sum + abs((b.posX - a.posX) * (c.posY - a.posY) - (b.posY - a.posY) * (c.posX - a.posX)) * 0.5
            }
            let outerRadius: Float = 10 + 0.5 / scale
            let expectedArea = (100 + 1 / scale) * (60 + 1 / scale) - (4 - Float.pi) * outerRadius * outerRadius
            #expect(abs(area - expectedArea) < 0.5)
        }
    }

    @Test("addText produces glyph quads with atlas UVs")
    func addTextGeometry() {
        let atlas = FontAtlas()
        atlas.loadFont(path: drawListTestFontPath, size: 16)

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
        atlas.loadFont(path: drawListTestFontPath, size: 16)

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

    @Test("Translated append moves vertices but preserves the parent scissor")
    func translatedAppend() {
        let source = DrawList()
        source.pushClip(UIRect(x: 0, y: 0, width: 100, height: 80))
        source.addRect(UIRect(x: 10, y: 20, width: 30, height: 40), color: .white)

        let destination = DrawList()
        destination.addRect(UIRect(x: 0, y: 0, width: 1, height: 1), color: .black)
        destination.append(source, vertexTranslationX: 7, vertexTranslationY: -5)

        #expect(destination.vertices[4].posX == 17)
        #expect(destination.vertices[4].posY == 15)
        #expect(destination.indices[6] == 4)
        #expect(destination.batches[1].indexOffset == 6)
        #expect(destination.batches[1].scissor == UIRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test("Appending into an empty list keeps source storage immutable")
    func emptyAppendCopyOnWrite() {
        let source = DrawList()
        source.addRect(UIRect(x: 10, y: 20, width: 30, height: 40), color: .white)

        let destination = DrawList()
        destination.append(source)
        #expect(destination.vertices.count == source.vertices.count)
        #expect(destination.vertices.first?.posX == source.vertices.first?.posX)
        #expect(destination.vertices.first?.posY == source.vertices.first?.posY)
        #expect(destination.indices == source.indices)
        #expect(destination.batches == source.batches)

        destination.addRect(UIRect(x: 50, y: 60, width: 10, height: 10), color: .black)
        #expect(destination.vertices.count == 8)
        #expect(source.vertices.count == 4)
        #expect(source.indices.count == 6)

        destination.reset()
        #expect(destination.vertices.isEmpty)
        #expect(source.vertices.count == 4)
        #expect(source.indices.count == 6)
    }

}
