import XCTest
import GuavaUICore
@testable import GuavaUIText

final class ColorGlyphAtlasTests: XCTestCase {
    private func bitmap(_ index: UInt32, size: Int = 2) -> ColorGlyphBitmap {
        let metrics = GlyphMetrics(glyphIndex: index, width: Float(size), height: Float(size),
            bearingX: 0, bearingY: Float(size), advance: Float(size + 1))
        return ColorGlyphBitmap(pixels: (0..<(size * size)).flatMap { _ in [UInt8(index), 20, 30, 128] },
            width: size, height: size, metrics: metrics)
    }
    private func source() -> ColorGlyphSource {
        ColorGlyphSource(size: 18, rasterScale: 1, metrics: { self.bitmap($0).metrics },
            lineMetrics: { GlyphLineMetrics(ascent: 2, descent: 1, lineHeight: 3) },
            rasterize: { self.bitmap($0) })
    }

    func testMetricsStayLazyAndRepeatRasterizationDoesNotDirty() throws {
        let atlas = FontAtlas(width: 16, height: 16)
        atlas.registerColorSource(source(), fontID: 1)
        XCTAssertEqual(atlas.glyphMetrics(glyphIndex: 2, fontID: 1)?.advance, 3)
        XCTAssertNil(atlas.colorDirtyUploadPayload())
        XCTAssertFalse(atlas.isDirty)
        let glyph = try XCTUnwrap(atlas.rasterizeGlyph(glyphIndex: 2, fontID: 1))
        XCTAssertEqual(glyph.format, .color)
        let payload = try XCTUnwrap(atlas.colorDirtyUploadPayload())
        XCTAssertEqual(payload.pixels, bitmap(2).pixels)
        XCTAssertEqual(payload.region.width, 2)
        XCTAssertNil(atlas.dirtyUploadPayload())
        atlas.markClean()
        XCTAssertFalse(atlas.isDirty)
        XCTAssertEqual(atlas.rasterizeGlyph(glyphIndex: 2, fontID: 1)?.uvMinX, glyph.uvMinX)
        XCTAssertFalse(atlas.isDirty)
    }

    func testRGBARegionPreservesRowsAndTransparentShelfSpacing() throws {
        let plane = ColorGlyphAtlas(width: 8, height: 8)
        _ = plane.insert(bitmap(1))
        _ = plane.insert(bitmap(2))
        let payload = try XCTUnwrap(plane.payload())
        XCTAssertEqual(payload.region.width, 5)
        XCTAssertEqual(payload.region.height, 2)
        let row: [UInt8] = [1, 20, 30, 128, 1, 20, 30, 128, 0, 0, 0, 0, 2, 20, 30, 128, 2, 20, 30, 128]
        XCTAssertEqual(payload.pixels, row + row)
        plane.markClean()
        _ = plane.insert(bitmap(3)) // new shelf
        let patch = try XCTUnwrap(plane.payload())
        XCTAssertEqual(patch.region.y, 3)
        XCTAssertEqual(patch.pixels, bitmap(3).pixels)
    }

    func testResetClearsBothPlanesAndExhaustionState() throws {
        let atlas = FontAtlas(width: 4, height: 4)
        atlas.registerColorSource(source(), fontID: 1)
        XCTAssertNotNil(atlas.rasterizeGlyph(glyphIndex: 1, fontID: 1))
        XCTAssertNil(atlas.rasterizeGlyph(glyphIndex: 2, fontID: 1))
        XCTAssertTrue(atlas.isFull)
        atlas.reset()
        XCTAssertFalse(atlas.isFull)
        XCTAssertNil(atlas.cachedGlyphInfo(glyphIndex: 1, fontID: 1))
        XCTAssertEqual(atlas.dirtyUploadPayload()?.pixels, [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(atlas.colorDirtyUploadPayload()?.pixels, [UInt8](repeating: 0, count: 64))
        XCTAssertNotNil(atlas.rasterizeGlyph(glyphIndex: 2, fontID: 1))
    }

    func testInvalidRGBADataDoesNotConsumeShelfSpace() throws {
        let plane = ColorGlyphAtlas(width: 8, height: 8)
        let valid = bitmap(1)
        XCTAssertNil(plane.insert(ColorGlyphBitmap(pixels: [0], width: 2, height: 2, metrics: valid.metrics)))
        XCTAssertNil(plane.payload())
        XCTAssertEqual(plane.insert(valid)?.uvMinX, 0)
        XCTAssertFalse(plane.isFull)
    }
}
