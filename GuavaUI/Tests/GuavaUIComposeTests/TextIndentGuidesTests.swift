import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Text indentation guides")
struct TextIndentGuidesTests {
    private func layout(_ source: TextBuffer, rows: Range<Int>? = nil) -> TextLayoutResult {
        let lines = (rows ?? 0..<source.lineCount).map { index in
            let range = source.lineRange(forLine: index)
            return TextLine(glyphs: [], baselineY: Float(index) * 20 + 16, topY: Float(index) * 20,
                            width: 100, startCluster: UInt32(source.utf8Offset(forCharacterIndex: range.lowerBound)),
                            endCluster: UInt32(source.utf8Offset(forCharacterIndex: range.upperBound)))
        }
        return TextLayoutResult(lines: lines, totalWidth: 100, totalHeight: Float(source.lineCount) * 20)
    }

    @Test("Nested scopes draw in preceding whitespace and join across blank lines without per-row gaps")
    func continuousScopes() {
        let source: TextBuffer = "func demo() {\n    first()\n\n    if ready {\n        next()\n    }\n}\n"
        let guides = TextIndentGuides.segments(in: layout(source), source: source, tabWidth: 4,
                                             spaceWidth: 8, lineHeight: 20, visibleX: 0..<200)
        #expect(guides.count == 2)
        #expect(guides.first?.x == 0.5 && guides.first?.top == 20 && guides.first?.height == 100)
        #expect(guides.last?.x == 32.5 && guides.last?.top == 80 && guides.last?.height == 20)
    }

    @Test("Scrolled windows recover blank-line context, tabs share columns and offscreen depths are bounded")
    func visibleWindow() {
        let source: TextBuffer = "root\n\tfirst\n\n\t\tsecond\nend"
        let guides = TextIndentGuides.segments(in: layout(source, rows: 2..<4), source: source, tabWidth: 4,
                                             spaceWidth: 8, lineHeight: 20, visibleX: 0..<200)
        #expect(guides.count == 2)
        #expect(guides.first?.top == 40 && guides.first?.height == 40)
        #expect(guides.last?.x == 32.5 && guides.last?.top == 60)
        #expect(TextIndentGuides.segments(in: layout(source), source: source, tabWidth: 4,
                                        spaceWidth: 8, lineHeight: 20, visibleX: 64..<200).isEmpty)
    }

    @Test("Soft-wrapped words do not receive a guide through their first glyph")
    func softWrap() {
        let source: TextBuffer = "    a long wrapped statement"
        let rows = TextLayoutResult(lines: [
            .init(glyphs: [], baselineY: 16, topY: 0, width: 100, startCluster: 0, endCluster: 11),
            .init(glyphs: [], baselineY: 36, topY: 20, width: 100, startCluster: 11, endCluster: UInt32(source.utf8Length)),
        ], totalWidth: 100, totalHeight: 40)
        let guides = TextIndentGuides.segments(in: rows, source: source, tabWidth: 4,
                                             spaceWidth: 8, lineHeight: 20, visibleX: 0..<200)
        #expect(guides.count == 1 && guides.first?.top == 0 && guides.first?.height == 20)
    }
}
