import Testing
@testable import GuavaUIRuntime

#if canImport(CoreText)
@Suite("Native color glyph raster pipeline", .serialized)
struct ColorGlyphTests {
    private func pipeline(size: Float = 18, scale: Float = 2) throws -> (FontProvider, FontAtlas) {
        let provider = FontProvider(size: size, rasterScale: scale)
        _ = try #require(provider.loadPrimaryFont(name: SystemFontDefaults.primaryFontName))
        return (provider, FontAtlas(width: 256, height: 256))
    }

    @Test("ZWJ, skin tone, regional flag and variation sequences remain single positioned glyphs",
           arguments: ["🙂", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇨🇳", "❤️"])
    func graphemeShaping(text: String) throws {
        let (provider, atlas) = try pipeline()
        let run = try #require(provider.resolveRuns(text: text).first)
        #expect(run.font.colorGlyphFont != nil)
        let shaped = provider.shapeRun(run)
        #expect(shaped.count == 1)
        let glyph = try #require(shaped.first)
        #expect(glyph.glyphID != 0 && glyph.cluster == 0 && glyph.xAdvance > 12)
        provider.registerAllFonts(in: atlas)
        let metrics = try #require(atlas.glyphMetrics(glyphIndex: glyph.glyphID, fontID: glyph.fontID))
        #expect(metrics.width > 12 && metrics.height > 12)
        #expect(abs(metrics.advance - glyph.xAdvance) < 0.01)
        // Measuring the font never allocates or dirties a color texture.
        #expect(!atlas.isDirty && atlas.colorDirtyUploadPayload() == nil)
        let info = try #require(atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID))
        #expect(info.format == .color && info.width == metrics.width && info.bearingY == metrics.bearingY)
        let payload = try #require(atlas.colorDirtyUploadPayload())
        #expect(atlas.isDirty && atlas.dirtyUploadPayload() == nil)
        #expect(payload.pixels.count == payload.region.width * payload.region.height * 4)
        let visible = stride(from: 0, to: payload.pixels.count, by: 4).filter { payload.pixels[$0 + 3] > 0 }
        #expect(!visible.isEmpty)
        #expect(visible.contains { abs(Int(payload.pixels[$0]) - Int(payload.pixels[$0 + 2])) > 30 })
        #expect(payload.pixels[3] == 0)
        atlas.markClean()
        _ = atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID)
        #expect(!atlas.isDirty)
        atlas.reset()
        #expect(atlas.cachedGlyphInfo(glyphIndex: glyph.glyphID, fontID: glyph.fontID) == nil)
        #expect(atlas.colorDirtyUploadPayload()?.pixels.allSatisfy { $0 == 0 } == true)
        _ = atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID)
        #expect(atlas.colorDirtyUploadPayload()?.pixels.contains { $0 != 0 } == true)
    }

    @Test("mixed text keeps global UTF8 clusters and separates alpha and color draw batches")
    func mixedText() throws {
        let (provider, atlas) = try pipeline()
        let text = "A👩🏽‍💻中🙂B"
        let glyphs = provider.resolveRuns(text: text).flatMap(provider.shapeRun)
        #expect(glyphs.map(\.cluster) == [0, 1, 16, 19, 23])
        #expect(glyphs.allSatisfy { $0.xAdvance > 0 && $0.glyphID != 0 })
        provider.registerAllFonts(in: atlas)
        let list = DrawList()
        let tint = Color(r: 1, g: 0, b: 0, a: 0.5)
        for glyph in glyphs {
            let info = try #require(atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID))
            list.addAtlasGlyph(info, x: 0, y: 0, color: tint, textureID: 1)
        }
        #expect(list.batches.map(\.textureID) == [1, TextureID(1).colorGlyphAtlasID, 1, TextureID(1).colorGlyphAtlasID, 1])
        #expect(atlas.dirtyUploadPayload() != nil && atlas.colorDirtyUploadPayload() != nil)
        #expect(list.vertices[0].color == tint.rgba8)
        #expect(list.vertices[4].color == Color(r: 1, g: 1, b: 1, a: 0.5).rgba8)
    }

    @Test("HiDPI increases physical resolution without doubling the logical advance")
    func rasterScale() throws {
        func measure(size: Float, scale: Float) throws -> (Float, Float, Float) {
            let (provider, atlas) = try pipeline(size: size, scale: scale)
            let run = try #require(provider.resolveRuns(text: "🙂").first)
            let glyph = try #require(provider.shapeRun(run).first)
            provider.registerAllFonts(in: atlas)
            let info = try #require(atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID))
            return (glyph.xAdvance, info.width, (info.uvMaxX - info.uvMinX) * Float(atlas.atlasWidth))
        }
        let base = try measure(size: 18, scale: 1), retina = try measure(size: 18, scale: 2)
        #expect(abs(base.0 - retina.0) < 0.1 && abs(base.1 - retina.1) <= 2)
        #expect(retina.2 > base.2 * 1.6)
        let large = try measure(size: 36, scale: 2)
        // The system bitmap font uses optical sizes; doubling the point size
        // need not double its advance exactly.
        #expect(large.0 > retina.0 * 1.7 && large.0 < retina.0 * 2.3)
    }
}
#endif
