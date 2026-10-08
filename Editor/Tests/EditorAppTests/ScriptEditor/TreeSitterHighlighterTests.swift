import Foundation
import GuavaUICompose
import Testing
@testable import EditorApp

@Suite("Incremental Swift syntax trees")
struct TreeSitterHighlighterTests {
    @Test("grammar classifies raw strings, interpolation, nested comments and function fields")
    func grammarTokens() throws {
        let text = ##"""
        @MainActor
        struct Example {
            /* outer /* inner */ still comment */
            let value = #"raw \#(compute(42)) text"#
            func compute(_ value: Int) -> Int { value }
        }
        """##
        let highlighter = TreeSitterHighlighter()
        #expect(highlighter.synchronize(TextBuffer(text)))
        #expect(highlighter.tree?.hasErrors == false)
        func kind(_ needle: String) throws -> SwiftSyntaxTokenKind? {
            let range = try #require(text.range(of: needle))
            return highlighter.kind(atUTF8Offset: text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound))
        }
        #expect(try kind("@") == .attribute)
        #expect(try kind("MainActor") == .attribute)
        #expect(try kind("struct") == .keyword)
        #expect(try kind("Example") == .typeName)
        #expect(try kind("inner") == .comment)
        #expect(try kind("raw") == .stringLiteral)
        #expect(try kind("compute(42)") == .functionName)
        #expect(try kind("42") == .number)
        #expect(try kind("compute(_") == .functionName)
        #expect(try kind("Int") == .typeName)
    }

    @Test("200K-line edits reuse distant subtrees and read bounded Rope chunks")
    func largeIncrementalParse() throws {
        var buffer = TextBuffer(String(repeating: "let value = 42\n", count: 200_000))
        let highlighter = TreeSitterHighlighter()
        let start = Date()
        #expect(highlighter.synchronize(buffer))
        print("Initial tree parse: \(Date().timeIntervalSince(start))s; reads \(highlighter.statistics.bytesRead)")
        let original = try #require(highlighter.tree)
        #expect(!original.hasErrors)
        let first = try #require(original.path(atUTF8Offset: 0).last).identity
        let lastOffset = buffer.utf8Offset(forCharacterIndex: buffer.lineRange(forLine: 199_999).lowerBound)
        let last = try #require(original.path(atUTF8Offset: lastOffset).last).identity
        #expect(highlighter.statistics.bytesRead >= buffer.utf8Length)
        let middle = buffer.lineRange(forLine: 100_000).upperBound - 1
        var largestRead = 0
        for iteration in 0..<30 {
            buffer = buffer.insert("1", atCharacterIndex: middle)
            #expect(highlighter.synchronize(buffer))
            #expect(highlighter.statistics.usedPreviousTree)
            if iteration < 4 { print("Iteration \(iteration): \(highlighter.statistics)") }
            largestRead = max(largestRead, highlighter.statistics.bytesRead)
            if iteration > 0 { #expect(highlighter.statistics.bytesRead < 20_000) }
        }
        let tree = try #require(highlighter.tree)
        #expect(!tree.hasErrors)
        #expect(tree.path(atUTF8Offset: 0).last?.identity == first)
        #expect(tree.path(atUTF8Offset: lastOffset + 30).last?.identity == last)
        // A retained snapshot still uses its original byte coordinates.
        #expect(original.path(atUTF8Offset: lastOffset).last?.identity == last)
        let count = highlighter.parseCount
        for offset in lastOffset..<(lastOffset + 15) { _ = highlighter.kind(atUTF8Offset: offset) }
        #expect(highlighter.synchronize(buffer) && highlighter.parseCount == count)
        #expect(highlighter.synchronize(TextBuffer(buffer.stringValue)) && highlighter.parseCount == count)
        #expect(Date().timeIntervalSince(start) < 30)
        print("Swift 200K-line parse and 30 edits: \(Date().timeIntervalSince(start))s; largest incremental read \(largestRead) bytes")
    }

    @Test("Unicode and CRLF edits produce the same tokens as a fresh parse, including undo")
    func incrementalEquivalence() {
        let initial: TextBuffer = "let 中文 = \"😀e\u{301}\"\r\nlet other = 7\r\n"
        let changed = initial.insert("/*注释*/", atCharacterIndex: initial.lineRange(forLine: 1).lowerBound)
        let incremental = TreeSitterHighlighter(), fresh = TreeSitterHighlighter()
        #expect(incremental.synchronize(initial) && incremental.synchronize(changed))
        #expect(fresh.synchronize(changed))
        for byte in 0..<changed.utf8Length {
            #expect(incremental.kind(atUTF8Offset: byte) == fresh.kind(atUTF8Offset: byte))
        }
        #expect(incremental.synchronize(initial) && fresh.synchronize(initial))
        for byte in 0..<initial.utf8Length {
            #expect(incremental.kind(atUTF8Offset: byte) == fresh.kind(atUTF8Offset: byte))
        }
    }
}
