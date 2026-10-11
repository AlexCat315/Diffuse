#if canImport(CoreText)
import CoreText
import CFreeType
import Testing
@testable import GuavaUIRuntime

@Suite("System font instances")
struct SystemFontInstanceTests {
    private func coordinates(_ font: ManagedFont) throws -> [UInt32: Double] {
        var descriptor: UnsafeMutablePointer<FT_MM_Var>?
        let face = font.rawFace
        #expect(FT_Get_MM_Var(face, &descriptor) == 0)
        let axes = try #require(descriptor)
        defer { FT_Done_MM_Var(face.pointee.glyph.pointee.library, axes) }
        var values = [FT_Fixed](repeating: 0, count: Int(axes.pointee.num_axis))
        #expect(FT_Get_Var_Design_Coordinates(face, axes.pointee.num_axis, &values) == 0)
        return Dictionary(uniqueKeysWithValues: values.enumerated().map {
            (UInt32(axes.pointee.axis[$0.offset].tag), Double($0.element) / 65_536)
        })
    }

    @Test("Requested system weights reach the shared FreeType face and change real outlines")
    func weights() throws {
        var areas: [UInt64] = []
        var widths: [Float] = []
        for weight in [FontWeight.regular, .medium, .semibold, .bold] {
            let provider = FontProvider(size: 16, rasterScale: 2)
            let font = try #require(provider.loadPrimaryFont(name: SystemFontDefaults.primaryFontName, weight: weight))
            let system = CTFontCreateUIFontForLanguage(.system, 16, nil)!
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system),
                [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight.coreTextWeight]] as CFDictionary)
            let expectedFont = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
            let expected = CTFontCopyVariation(expectedFont) as? [NSNumber: NSNumber] ?? [:]
            let actual = try coordinates(font)
            for (tag, value) in expected {
                #expect(abs((actual[tag.uint32Value] ?? -1) - value.doubleValue) < 0.001)
            }
            let atlas = FontAtlas()
            provider.registerAllFonts(in: atlas)
            let run = try #require(provider.resolveRuns(text: "Hamburgefonts 0123456789").first)
            let glyphs = provider.shapeRun(run)
            widths.append(glyphs.reduce(0) { $0 + $1.xAdvance })
            for glyph in glyphs { _ = atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID) }
            areas.append(atlas.atlasData.reduce(0) { $0 + UInt64($1) })
        }
        #expect(zip(areas, areas.dropFirst()).allSatisfy { $0 < $1 })
        #expect(widths.last! > widths.first!)
    }

    @Test("Display density changes raster resolution without selecting a different optical size or spacing")
    func opticalSize() throws {
        for size: Float in [13, 24, 34] {
            var widths: [Float] = []
            var instances: [[UInt32: Double]] = []
            for scale: Float in [1, 2] {
                let provider = FontProvider(size: size, rasterScale: scale)
                let font = try #require(provider.loadPrimaryFont(name: SystemFontDefaults.primaryFontName, weight: .semibold))
                instances.append(try coordinates(font))
                widths.append(provider.resolveRuns(text: "Dashboard · English 54.8 MB/s").flatMap(provider.shapeRun).reduce(0) { $0 + $1.xAdvance })
            }
            #expect(instances[0] == instances[1])
            #expect(abs(widths[0] - widths[1]) < 0.3)
        }
    }
}
#endif
