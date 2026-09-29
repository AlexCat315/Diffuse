import Testing
@testable import EditorApp

@Suite("Swift script syntax highlighting")
struct ScriptCodeEditorTests {
    @Test("colors Swift declarations, types, strings, comments, numbers, and attributes")
    func highlightsCommonSwiftTokens() throws {
        let source = """
        @_cdecl("entry")
        struct GameScript {
            // note
            let count = 42
            func update() {}
        }
        """
        let highlighter = SwiftSyntaxHighlighter(source)

        #expect(highlighter.color(atUTF8Offset: try #require(source.utf8Offset(of: "struct"))) != nil)
        #expect(highlighter.color(atUTF8Offset: try #require(source.utf8Offset(of: "GameScript"))) != nil)
        #expect(highlighter.color(atUTF8Offset: try #require(source.utf8Offset(of: "\"entry\""))) != nil)
        #expect(highlighter.color(atUTF8Offset: try #require(source.utf8Offset(of: "// note"))) != nil)
        #expect(highlighter.color(atUTF8Offset: try #require(source.utf8Offset(of: "42"))) != nil)
        #expect(highlighter.color(atUTF8Offset: try #require(source.utf8Offset(of: "@_cdecl"))) != nil)
        #expect(highlighter.color(atUTF8Offset: try #require(source.utf8Offset(of: "update"))) != nil)
    }

    @Test("leaves whitespace and punctuation in the default foreground")
    func leavesUnclassifiedTextUncolored() throws {
        let source = "let answer = 42"
        let highlighter = SwiftSyntaxHighlighter(source)
        let equalsOffset = try #require(source.utf8Offset(of: " = ")) + 1
        #expect(highlighter.color(atUTF8Offset: equalsOffset) == nil)
    }
}

private extension String {
    func utf8Offset(of substring: String) -> Int? {
        guard let range = range(of: substring),
              let utf8Index = range.lowerBound.samePosition(in: utf8) else {
            return nil
        }
        return utf8.distance(from: utf8.startIndex, to: utf8Index)
    }
}