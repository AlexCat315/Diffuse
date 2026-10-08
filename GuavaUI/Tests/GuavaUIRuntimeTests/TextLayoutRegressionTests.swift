import Testing
@testable import GuavaUIRuntime

@Suite("Text layout boundary contracts")
struct TextLayoutRegressionTests {
    private final class Metrics: GlyphMetricsProvider {
        func glyphMetrics(glyphIndex: UInt32, fontID: Int) -> GlyphMetrics? { nil }
        func lineMetrics(fontID: Int) -> GlyphLineMetrics? {
            GlyphLineMetrics(ascent: fontID == 0 ? 12 : 14, descent: fontID == 0 ? 4 : 6, lineHeight: 20)
        }
    }
    private func glyph(_ cluster: UInt32, advance: Float = 5, font: Int = 0) -> ShapedGlyph {
        ShapedGlyph(glyphID: 1, xOffset: 0, yOffset: 0, xAdvance: advance, yAdvance: 0, cluster: cluster, fontID: font)
    }

    @Test("CRLF is one break; empty and trailing lines preserve their source ranges and baselines")
    func emptyLinesAndCRLF() {
        let text = "A\r\n\r\nB\n"
        let result = TextLayout.layout(shapedGlyphs: (0..<text.utf8.count).map { glyph(UInt32($0)) }, text: text, atlas: Metrics(), lineHeight: 20)
        #expect(result.lines.count == 4 && result.totalHeight == 80)
        #expect(result.lines.map(\.startCluster) == [0, 3, 5, 7])
        #expect(result.lines.map(\.endCluster) == [1, 3, 6, 7])
        #expect(result.lines.map(\.baselineY) == [14, 34, 54, 74])
        #expect(result.lines.map { $0.glyphs.count } == [1, 0, 1, 0])
    }

    @Test("Mixed fallback fonts share a baseline; short line height distributes leading on both sides")
    func commonFontMetrics() {
        let result = TextLayout.layout(shapedGlyphs: [glyph(0), glyph(1), glyph(2, font: 1)], text: "A\nB", atlas: Metrics(), lineHeight: 16)
        #expect(result.lines.map(\.baselineY) == [12, 28])
    }

    @Test("Unicode line and paragraph separators agree with the text buffer's line boundaries")
    func unicodeSeparators() {
        let result = TextLayout.layout(shapedGlyphs: [glyph(0), glyph(1), glyph(4), glyph(5), glyph(8)], text: "A\u{2028}B\u{2029}C", atlas: Metrics(), lineHeight: 20)
        #expect(result.lines.map(\.startCluster) == [0, 4, 8])
        #expect(result.lines.map(\.endCluster) == [1, 5, 9])
        #expect(result.lines.map { $0.glyphs.count } == [1, 1, 1])
    }

    @Test("Tracking is between clusters; wrapping never separates glyphs in one cluster")
    func clusterTrackingAndWrapping() {
        let glyphs = [glyph(0, advance: 3), glyph(0, advance: 2), glyph(3, advance: 4)]
        let spaced = TextLayout.layout(shapedGlyphs: glyphs, text: "áB", atlas: Metrics(), lineHeight: 20, letterSpacing: 2)
        #expect(spaced.totalWidth == 11)
        #expect(spaced.lines[0].glyphs.map(\.x) == [0, 3, 7])
        let wrapped = TextLayout.layout(shapedGlyphs: glyphs, text: "áB", atlas: Metrics(), maxWidth: 4, lineHeight: 20)
        #expect(wrapped.lines.map { $0.glyphs.count } == [2, 1])
        let trackedWrap = TextLayout.layout(shapedGlyphs: [glyph(0), glyph(1)], text: "AB", atlas: Metrics(), maxWidth: 10, lineHeight: 20, letterSpacing: 1)
        #expect(trackedWrap.lines.map(\.width) == [5, 5])
    }
}
