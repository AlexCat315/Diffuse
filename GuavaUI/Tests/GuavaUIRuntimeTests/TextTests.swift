import Testing
import GuavaUIBundledFonts
@testable import GuavaUIRuntime

/// Cross-platform test font: the bundled Inter.ttc, present on every platform.
private let testFontPath = BundledFonts.bundledFontURL?.path ?? ""

@Suite("Text")
struct TextTests {

    // MARK: - FreeType

    @Test("FontAtlas initializes FreeType and loads a font")
    func fontAtlasInit() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)
        #expect(atlas.freetypeFace != nil)
    }

    @Test("Rasterize ASCII 'A' produces non-empty bitmap")
    func rasterizeA() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 24)

        let info = atlas.rasterizeCodepoint(0x41)  // 'A'
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
        #expect(info!.advance > 0)
    }

    @Test("Rasterizing the same glyph twice returns cached result")
    func rasterizeCache() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)

        let a = atlas.rasterizeCodepoint(0x42)  // 'B'
        let b = atlas.rasterizeCodepoint(0x42)
        #expect(a != nil)
        #expect(b != nil)
        #expect(a!.uvMinX == b!.uvMinX)
        #expect(a!.uvMinY == b!.uvMinY)
    }

    @Test("Atlas packs multiple glyphs without UV overlap")
    func atlasNoOverlap() {
        let atlas = FontAtlas(width: 512, height: 512)
        atlas.loadFont(path: testFontPath, size: 20)

        var infos: [FontAtlas.GlyphInfo] = []
        // Rasterize printable ASCII
        for cp: UInt32 in 33...126 {
            if let info = atlas.rasterizeCodepoint(cp) {
                infos.append(info)
            }
        }

        #expect(infos.count > 80)

        // Verify no UV overlap (simplified: check pixel rects don't overlap)
        for i in 0..<infos.count {
            for j in (i+1)..<infos.count {
                let a = infos[i], b = infos[j]
                // At least one axis must not overlap
                let noOverlap =
                    a.uvMaxX <= b.uvMinX || b.uvMaxX <= a.uvMinX ||
                    a.uvMaxY <= b.uvMinY || b.uvMaxY <= a.uvMinY
                #expect(noOverlap, "Glyph \(a.glyphIndex) overlaps with \(b.glyphIndex)")
            }
        }
    }

    @Test("Atlas reset clears data and cache")
    func atlasReset() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)
        _ = atlas.rasterizeCodepoint(0x41)

        atlas.reset()

        // Atlas data should be all zeros
        let nonZero = atlas.atlasData.contains { $0 != 0 }
        #expect(!nonZero)
    }

    @Test("HiDPI atlas keeps logical metrics while increasing bitmap resolution")
    func hidpiAtlasMetrics() {
        let base = FontAtlas(width: 512, height: 512)
        base.loadFont(path: testFontPath, size: 24)

        let hidpi = FontAtlas(width: 1024, height: 1024)
        hidpi.loadFont(path: testFontPath, size: 24, rasterScale: 2)

        let baseInfo = base.rasterizeCodepoint(0x41)
        let hidpiInfo = hidpi.rasterizeCodepoint(0x41)
        #expect(baseInfo != nil)
        #expect(hidpiInfo != nil)

        let basePhysicalWidth = (baseInfo!.uvMaxX - baseInfo!.uvMinX) * Float(base.atlasWidth)
        let hidpiPhysicalWidth = (hidpiInfo!.uvMaxX - hidpiInfo!.uvMinX) * Float(hidpi.atlasWidth)

        #expect(abs(baseInfo!.width - hidpiInfo!.width) < 2)
        #expect(abs(baseInfo!.advance - hidpiInfo!.advance) < 2)
        #expect(hidpiPhysicalWidth > basePhysicalWidth)
    }

    // MARK: - HarfBuzz

    @Test("TextShaper shapes 'Hello' into 5 glyphs")
    func shapeHello() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let glyphs = shaper.shape(text: "Hello")
        #expect(glyphs.count == 5)

        // All advances should be positive
        for g in glyphs {
            #expect(g.xAdvance > 0)
        }
    }

    // CJK shaping needs a CJK-capable system font + CoreText fallback, which is
    // Apple-only. (The bundled Inter font is Latin; no portable CJK fallback yet.)
    #if canImport(CoreText)
    @Test("TextShaper shapes CJK text")
    func shapeCJK() {
        let atlas = FontAtlas()
        // Use a font that supports CJK
        let cjkFontPath = "/System/Library/Fonts/SFNS.ttf"
        atlas.loadFont(path: cjkFontPath, size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let glyphs = shaper.shape(text: "你好")
        #expect(glyphs.count == 2)
    }
    #endif

    @Test("TextShaper advances accumulate correctly")
    func shapeAdvances() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let glyphs = shaper.shape(text: "AB")
        #expect(glyphs.count == 2)

        // Total width should be sum of advances
        let total = glyphs.reduce(Float(0)) { $0 + $1.xAdvance }
        #expect(total > 0)
    }

    @Test("HiDPI shaping preserves logical advances")
    func hidpiShapingKeepsLogicalAdvance() {
        let baseAtlas = FontAtlas()
        baseAtlas.loadFont(path: testFontPath, size: 16)

        let baseShaper = TextShaper()
        baseShaper.setFont(ftFace: baseAtlas.freetypeFace!, size: 16)

        let hidpiAtlas = FontAtlas(width: 1024, height: 1024)
        hidpiAtlas.loadFont(path: testFontPath, size: 16, rasterScale: 2)

        let hidpiShaper = TextShaper()
        hidpiShaper.setFont(ftFace: hidpiAtlas.freetypeFace!, size: 16, rasterScale: 2)

        let baseAdvance = baseShaper.shape(text: "Hello").reduce(Float(0)) { $0 + $1.xAdvance }
        let hidpiAdvance = hidpiShaper.shape(text: "Hello").reduce(Float(0)) { $0 + $1.xAdvance }

        #expect(abs(baseAdvance - hidpiAdvance) < 2)
    }

    @Test("FontProvider keeps the macOS system primary font during fallback resolution")
    func fontProviderKeepsSystemPrimaryFont() {
        let provider = FontProvider(size: 13)
        let primary = provider.loadPrimaryFont(name: SystemFontDefaults.primaryFontName)

        #expect(primary != nil)

        let runs = provider.resolveRuns(text: "Scene Hierarchy")
        #expect(runs.isEmpty == false)
        #expect(runs.allSatisfy { $0.font.postScriptName == primary?.postScriptName })
    }

    // CJK fallback resolution is Apple CoreText-only; the portable FreeType path
    // ships no CJK font, so these only run where CoreText is available.
    #if canImport(CoreText)
    @Test("Bootstrapped system-font environment shapes CJK through fallback")
    func bootstrappedSystemFontShapesCJK() {
        let provider = FontProvider(size: 13)
        let primary = provider.loadPrimaryFont(name: SystemFontDefaults.primaryFontName)
        let runs = provider.resolveRuns(text: "你")
        let glyphs = runs.flatMap(provider.shapeRun)

        #expect(primary != nil)
        #expect(runs.isEmpty == false)
        #expect(glyphs.isEmpty == false)
        #expect((glyphs.first?.xAdvance ?? 0) > 0)
    }

    @Test("FontProvider shapes CJK through fallback for demo-sized HiDPI text")
    func fontProviderShapesCJKForDemoSizedHiDPIText() {
        let provider = FontProvider(size: 14, rasterScale: 2)
        let primary = provider.loadPrimaryFont(name: SystemFontDefaults.primaryFontName)
        let runs = provider.resolveRuns(text: "你")
        let glyphs = runs.flatMap(provider.shapeRun)

        #expect(primary != nil)
        #expect(runs.isEmpty == false)
        #expect(runs.first?.font.postScriptName != primary?.postScriptName)
        #expect(glyphs.isEmpty == false)
        #expect(glyphs.first?.glyphID != 0)
        #expect((glyphs.first?.xAdvance ?? 0) > 0)
    }
    #endif

    // MARK: - TextLayout

    @Test("Single-line layout for short text")
    func singleLineLayout() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let shaped = shaper.shape(text: "Hello")
        let result = TextLayout.layout(
            shapedGlyphs: shaped,
            text: "Hello",
            atlas: atlas,
            lineHeight: 20
        )

        #expect(result.lines.count == 1)
        #expect(result.lines[0].glyphs.count == 5)
        #expect(result.totalWidth > 0)
        #expect(result.totalHeight == 20)
    }

    @Test("Multi-line layout wraps at maxWidth")
    func multiLineWrap() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let text = "The quick brown fox jumps over the lazy dog"
        let shaped = shaper.shape(text: text)
        let result = TextLayout.layout(
            shapedGlyphs: shaped,
            text: text,
            atlas: atlas,
            maxWidth: 100,
            lineHeight: 20
        )

        #expect(result.lines.count > 1)
        // Each line should not exceed maxWidth (with tolerance for last glyph)
        for line in result.lines {
            #expect(line.width < 120)
        }
    }

    @Test("Multi-line baselines stay stable across different glyph shapes")
    func multilineBaselinesStayStable() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let text = "HI\ngj"
        let shaped = shaper.shape(text: text)
        let result = TextLayout.layout(
            shapedGlyphs: shaped,
            text: text,
            atlas: atlas,
            lineHeight: 20
        )

        #expect(result.lines.count == 2)
        let baselineStep = result.lines[1].baselineY - result.lines[0].baselineY
        #expect(abs(baselineStep - 20) < 0.5)
    }

    @Test("Layout reads metrics without rasterizing glyph bitmaps")
    func layoutDoesNotRasterize() {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)
        atlas.markClean()

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let shaped = shaper.shape(text: "AB")
        let result = TextLayout.layout(
            shapedGlyphs: shaped,
            text: "AB",
            atlas: atlas,
            lineHeight: 20
        )

        #expect(!atlas.isDirty)

        // Layout should not eagerly attach atlas info anymore.
        for glyph in result.lines[0].glyphs {
            #expect(glyph.atlasInfo == nil)
        }
    }

    @Test("Explicit newline forces line break")
    func explicitNewline() throws {
        let atlas = FontAtlas()
        atlas.loadFont(path: testFontPath, size: 16)

        let shaper = TextShaper()
        shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)

        let text = "hello\nworld"
        let shaped = shaper.shape(text: text)
        let result = TextLayout.layout(
            shapedGlyphs: shaped,
            text: text,
            atlas: atlas,
            lineHeight: 20
        )

        #expect(result.lines.count == 2)
    }
}
