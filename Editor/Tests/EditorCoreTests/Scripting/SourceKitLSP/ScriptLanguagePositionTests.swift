import Foundation
import Testing
@testable import EditorCore

@Suite("Editor index ↔ LSP position conversion")
struct ScriptLanguagePositionTests {
    @Test("maps single-line offsets to UTF-16 characters")
    func mapsSingleLine() {
        let text = "let x = 1"

        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 0)
            == ScriptLanguagePosition(line: 0, character: 0))
        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 4)
            == ScriptLanguagePosition(line: 0, character: 4))
        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: text.count)
            == ScriptLanguagePosition(line: 0, character: text.count))
    }

    @Test("counts non-BMP characters as two UTF-16 units")
    func countsSurrogatePairs() {
        let text = "ab😀cd"

        let beforeEmoji = ScriptSourceCoordinates.position(in: text, atCharacterIndex: 2)
        let afterEmoji = ScriptSourceCoordinates.position(in: text, atCharacterIndex: 3)

        #expect(beforeEmoji == ScriptLanguagePosition(line: 0, character: 2))
        #expect(afterEmoji == ScriptLanguagePosition(line: 0, character: 4))
    }

    @Test("advances lines and keeps a caret at end of line on that line")
    func tracksLines() {
        let text = "abc\ndef"

        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 3)
            == ScriptLanguagePosition(line: 0, character: 3))
        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 4)
            == ScriptLanguagePosition(line: 1, character: 0))
        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 7)
            == ScriptLanguagePosition(line: 1, character: 3))
    }

    @Test("handles a trailing newline as its own final line")
    func handlesTrailingNewline() {
        let text = "abc\n"

        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 3)
            == ScriptLanguagePosition(line: 0, character: 3))
        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 4)
            == ScriptLanguagePosition(line: 1, character: 0))
    }

    @Test("clamps out-of-range indices instead of trapping")
    func clampsInvalidIndices() {
        let text = "abc"

        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: -5)
            == ScriptLanguagePosition(line: 0, character: 0))
        #expect(ScriptSourceCoordinates.position(in: text, atCharacterIndex: 99)
            == ScriptLanguagePosition(line: 0, character: 3))
        #expect(ScriptSourceCoordinates.position(in: "", atCharacterIndex: 0) == .zero)
    }

    @Test("round-trips through characterIndex for CJK content")
    func roundTripsCJK() {
        let text = "变量 timer\n_ = 秒"

        for index in 0...text.count {
            let position = ScriptSourceCoordinates.position(in: text, atCharacterIndex: index)
            #expect(ScriptSourceCoordinates.characterIndex(in: text, at: position) == index)
        }
    }

    @Test("clamps a server reply that lands past the end of a line")
    func clampsOversizedServerPosition() {
        let text = "abc\ndef"

        let index = ScriptSourceCoordinates.characterIndex(
            in: text,
            at: ScriptLanguagePosition(line: 0, character: 99)
        )

        // End of line 0 — before the newline.
        #expect(index == 3)
    }

    @Test("extracts the enclosing identifier")
    func extractsIdentifier() throws {
        let text = "context.deltaTime += 1"

        let range = try #require(ScriptSourceCoordinates.identifierRange(in: text, containing: 12))
        #expect(String(text[text.index(text.startIndex, offsetBy: range.lowerBound)..<text.index(text.startIndex, offsetBy: range.upperBound)]) == "deltaTime")
    }

    @Test("returns the identifier trailing the caret when on punctuation")
    func handlesTrailingCaret() throws {
        let text = "context.delta"

        let range = try #require(ScriptSourceCoordinates.identifierRange(in: text, containing: text.count))
        // "context." occupies indices 0..<8, so the trailing word is 8..<13.
        #expect(range == 8..<13)
    }

    @Test("reports no identifier for whitespace or lone punctuation")
    func reportsNoIdentifier() {
        let text = "  ,  "

        #expect(ScriptSourceCoordinates.identifierRange(in: text, containing: 2) == nil)
    }

    @Test("converts positions to UTF-8 offsets for highlighting")
    func convertsToUTF8Offset() {
        // "é" is one UTF-16 unit but two UTF-8 bytes, so column 1 (the space)
        // maps to byte offset 2 and column 2 ("x") maps to 3.
        let text = "é x"

        #expect(ScriptSourceCoordinates.utf8Offset(in: text,
                                                  at: ScriptLanguagePosition(line: 0, character: 1)) == 2)
        #expect(ScriptSourceCoordinates.utf8Offset(in: text,
                                                  at: ScriptLanguagePosition(line: 0, character: 2)) == 3)
    }
}
