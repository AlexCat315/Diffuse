import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Visible Rope line shaping", .serialized)
struct TextDocumentLayoutTests: GuavaUIComposeSerializedSuite {
    private func geometry(_ env: TextEnvironment, width: Float = .infinity, secure: Bool = false) -> TextLineGeometry {
        TextLineGeometry(font: .system(size: 14), lineHeight: 20, letterSpacing: 0,
                         atlas: ObjectIdentifier(env.atlas), width: width, secure: secure)
    }
    @Test("200K lines shape only a visible window; middle edits retain the neighboring cache")
    func largeDocument() { GlobalTestLock.locked {
        let env = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        var buffer = TextBuffer(String(repeating: "let example = 123\n", count: 200_000))
        let layout = TextDocumentLayout(buffer: buffer, geometry: geometry(env))
        let first = layout.visibleLayout(firstRow: 100_000, rowCount: 40, environment: env)
        #expect(first.lines.count == 40)
        #expect(layout.shapedLineCount == 40 && layout.shapedUTF8Count < 1_000)
        #expect(first.totalHeight == 4_000_020)
        #expect(first.lines.first!.startCluster == buffer.utf8Offset(forCharacterIndex: buffer.lineRange(forLine: 100_000).lowerBound))
        _ = layout.visibleLayout(firstRow: 100_000, rowCount: 40, environment: env)
        #expect(layout.shapedLineCount == 40)
        let started = Date()
        for _ in 0..<100 {
            let range = buffer.lineRange(forLine: 100_020)
            buffer = buffer.insert("a", atCharacterIndex: range.upperBound)
            layout.update(buffer: buffer, geometry: geometry(env))
            _ = layout.visibleLayout(firstRow: 100_000, rowCount: 40, environment: env)
        }
        #expect(layout.shapedLineCount == 140)
        #expect(layout.index.lineCount == buffer.lineCount && layout.index.rowCount == buffer.lineCount)
        #expect(Date().timeIntervalSince(started) < 10)
    } }
    @Test("Wrapped line heights survive newline edits and reset when width changes")
    func incrementalWrapping() { GlobalTestLock.locked {
        let env = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        var buffer = TextBuffer("abcdefghijklmno\nsecond wrapped sentence\nend")
        let metrics = geometry(env, width: 50)
        let layout = TextDocumentLayout(buffer: buffer, geometry: metrics)
        _ = layout.visibleLayout(firstRow: 0, rowCount: 100, environment: env)
        let thirdRow = layout.index.firstRow(ofLine: 2)
        #expect(thirdRow > 2)
        let measured = layout.shapedLineCount
        buffer = buffer.insert("\n", atCharacterIndex: buffer.lineRange(forLine: 1).lowerBound)
        layout.update(buffer: buffer, geometry: metrics)
        _ = layout.visibleLayout(firstRow: 0, rowCount: 100, environment: env)
        #expect(layout.index.lineCount == 4)
        #expect(layout.shapedLineCount == measured + 2)
        #expect(layout.index.firstRow(ofLine: 3) == thirdRow + 1)
        layout.update(buffer: buffer, geometry: geometry(env))
        #expect(layout.index.rowCount == 4)
        _ = layout.visibleLayout(firstRow: 0, rowCount: 100, environment: env)
        #expect(layout.index.rowCount == 4)
    } }
    @Test("Caret and hit testing share grapheme stops for combining text, emoji and secure masks")
    func graphemeCaretStops() { GlobalTestLock.locked {
        let env = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        let buffer = TextBuffer("Ae\u{301}👩🏽‍💻中Z\n\nend")
        for secure in [false, true] {
            let layout = TextDocumentLayout(buffer: buffer, geometry: geometry(env, secure: secure))
            let visible = layout.visibleLayout(firstRow: 0, rowCount: 10, environment: env)
            #expect(visible.lines.count == 3)
            for character in 0...buffer.lineRange(forLine: 0).upperBound {
                let caret = layout.caret(atCharacter: character, environment: env)
                #expect(caret.row == 0)
                #expect(layout.character(atRow: caret.row, x: caret.x, environment: env) == character)
            }
            let blank = layout.caret(atCharacter: buffer.lineRange(forLine: 1).lowerBound, environment: env)
            #expect(blank.x == 0 && blank.row == 1)
            for glyph in visible.lines.flatMap(\.glyphs) {
                let character = buffer.characterIndex(forUTF8Offset: Int(glyph.cluster))
                #expect(buffer.utf8Offset(forCharacterIndex: character) == Int(glyph.cluster))
            }
        }
    } }
}
