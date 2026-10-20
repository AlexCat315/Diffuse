import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUIText

@Suite("FreeType color glyph source")
struct ColorGlyphResampleTests {
    @Test("Box resampling averages coverage and weights color by alpha")
    func resample() {
        // 2×2: opaque red, transparent black, opaque red, transparent black → 1×1.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 0]
        let result = FreeTypeColorGlyphFace.resample(pixels, width: 2, height: 2, toWidth: 1, toHeight: 1)
        #expect(result == [255, 0, 0, 127])
    }

    @Test("A face without color tables does not create a color source")
    func monochromeFace() {
        let atlas = FontAtlas(width: 64, height: 64)
        atlas.loadFont(path: systemTestFontPath(), size: 16)
        guard let face = atlas.freetypeFace else { return }
        #expect(!FreeTypeColorGlyphFace.hasColorGlyphs(face))
        #expect(FreeTypeColorGlyphFace(face: face, size: 16, rasterScale: 1) == nil)
    }
}
