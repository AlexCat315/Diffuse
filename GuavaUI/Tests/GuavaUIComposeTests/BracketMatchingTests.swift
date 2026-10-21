import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Text bracket matching")
struct BracketMatchingTests {
    @Test("Ordinary typing and caret movement do not scan the document")
    func ordinaryText() {
        let buffer = TextBuffer(String(repeating: "a", count: 200_000))
        let matcher = TextBracketMatching()
        for caret in [0, 10, 100_000, 199_999, 200_000] {
            #expect(matcher.pair(in: buffer, caretIndex: caret).isEmpty)
        }
        #expect(matcher.scannedUTF8Count == 0)
    }

    @Test("Nested pairs skip brackets inside strings and comments")
    func codeOnly() {
        let text = "你好({\"}\" /* ) */ [1]})"
        let buffer = TextBuffer(text)
        let matcher = TextBracketMatching()
        let opening = "你好".utf8.count
        #expect(matcher.pair(in: buffer, caretIndex: 2) == [opening, text.utf8.count - 1])
        #expect(matcher.pair(in: buffer, caretIndex: buffer.characterCount) == [text.utf8.count - 1, opening])
        #expect(matcher.pair(in: TextBuffer("// ()"), caretIndex: 3).isEmpty)
        #expect(matcher.pair(in: TextBuffer("\"()\""), caretIndex: 1).isEmpty)
    }

    @Test("Redraws reuse a pair and edits invalidate it, including missing matches")
    func revisionCache() {
        let matcher = TextBracketMatching()
        let buffer = TextBuffer("(hello)")
        #expect(matcher.pair(in: buffer, caretIndex: 0) == [0, 6])
        let scanned = matcher.scannedUTF8Count
        for _ in 0..<60 { #expect(matcher.pair(in: buffer, caretIndex: 0) == [0, 6]) }
        #expect(matcher.scannedUTF8Count == scanned)
        let edited = buffer.delete(characterRange: 6..<7)
        #expect(matcher.pair(in: edited, caretIndex: 0).isEmpty)
        let missing = matcher.scannedUTF8Count
        #expect(matcher.pair(in: edited, caretIndex: 0).isEmpty)
        #expect(matcher.scannedUTF8Count == missing)
        #expect(matcher.pair(in: .empty, caretIndex: 99).isEmpty)
    }
}
