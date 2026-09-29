import Foundation
import Testing
@testable import EditorCore

@Suite("SourceKit-LSP reply decoding")
struct ScriptLanguageReplyTests {
    // MARK: Hover

    @Test("decodes MarkupContent with a markdown declaration")
    func decodesMarkupContent() throws {
        let payload = Data(#"{"contents":{"kind":"markdown","value":"```swift\nvar deltaTime: Float\n```\nSeconds elapsed."},"range":{"start":{"line":3,"character":4},"end":{"line":3,"character":13}}}"#.utf8)

        let result = try #require(ScriptLanguageReplies.parseHover(payload))

        #expect(result.kind == .markdown)
        #expect(result.plainText.contains("var deltaTime: Float"))
        #expect(result.plainText.contains("Seconds elapsed."))
        #expect(result.span == ScriptLanguageSpan(startLine: 3, startCharacter: 4,
                                                  endLine: 3, endCharacter: 13))
    }

    @Test("decodes a legacy MarkedString payload")
    func decodesMarkedString() throws {
        let payload = Data(#"{"contents":{"language":"swift","value":"func foo()"}}"#.utf8)

        let result = try #require(ScriptLanguageReplies.parseHover(payload))

        #expect(result.kind == .plaintext)
        #expect(result.plainText == "func foo()")
    }

    @Test("returns nil for a null hover result")
    func returnsNilForEmptyHover() {
        #expect(ScriptLanguageReplies.parseHover(nil) == nil)
        #expect(ScriptLanguageReplies.parseHover(Data("null".utf8)) == nil)
    }

    @Test("strips markdown decorations from the summary")
    func stripsMarkdown() {
        let markdown = """
        ### Declaration

        ```swift
        static func clamp(_ v: Int) -> Int
        ```

        Clamps **v** to the [limit](https://example.com).

        - lo: lower bound
        """
        let summary = ScriptMarkdownText.plainSummary(markdown)

        #expect(summary.hasPrefix("static func clamp(_ v: Int) -> Int"))
        #expect(summary.contains("Clamps v to the limit"))
        #expect(!summary.contains("**"))
        #expect(!summary.contains("https://"))
        #expect(summary.contains("• lo: lower bound"))
        #expect(!summary.localizedCaseInsensitiveContains("### Declaration"))
    }

    // MARK: Completion

    @Test("decodes a CompletionList")
    func decodesCompletionList() {
        let payload = Data(#"{"isIncomplete":true,"items":[{"label":"deltaTime","kind":5,"detail":"Float","insertText":"deltaTime","textEdit":{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}},"newText":"deltaTime"}}]}"#.utf8)

        let result = ScriptLanguageReplies.parseCompletion(payload)

        #expect(result.isIncomplete)
        #expect(result.items.count == 1)
        #expect(result.items.first?.kind == .field)
        #expect(result.items.first?.replaceStart == ScriptLanguagePosition(line: 2, character: 4))
    }

    @Test("accepts a bare array of completion items")
    func decodesCompletionArray() {
        let payload = Data(#"[{"label":"onUpdate","kind":2}]"#.utf8)

        let result = ScriptLanguageReplies.parseCompletion(payload)

        #expect(result.items.count == 1)
        #expect(result.items.first?.insertText == "onUpdate")
        #expect(result.items.first?.kind == .method)
    }

    // MARK: Definition

    @Test("decodes Location and LocationLink shapes")
    func decodesDefinitionShapes() {
        let location = Data(#"{"uri":"file:///a.swift","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}}"#.utf8)
        let link = Data(#"[{"targetUri":"file:///b.swift","targetRange":{"start":{"line":9,"character":2},"end":{"line":9,"character":6}},"targetSelectionRange":{"start":{"line":9,"character":2},"end":{"line":9,"character":6}},"originSelectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":4}}}]"#.utf8)

        let single = ScriptLanguageReplies.parseDefinition(location)
        let multiple = ScriptLanguageReplies.parseDefinition(link)

        #expect(single.count == 1)
        #expect(single.first?.documentURI == "file:///a.swift")
        #expect(single.first?.span.start.line == 1)
        #expect(multiple.count == 1)
        #expect(multiple.first?.documentURI == "file:///b.swift")
    }

    // MARK: Diagnostics

    @Test("parses a publishDiagnostics notification")
    func parsesDiagnostics() throws {
        let params = try LSPJSON.data([
            "uri": "file:///Script.swift",
            "version": 4,
            "diagnostics": [
                ["range": ["start": ["line": 2, "character": 1],
                           "end": ["line": 2, "character": 5]],
                 "severity": 1,
                 "code": "cannot-find-type",
                 "message": "cannot find type 'Foo' in scope"],
            ],
        ])
        let notification = SourceKitLSPNotification(method: "textDocument/publishDiagnostics",
                                                    params: params)

        let published = try #require(ScriptLanguageReplies.parseDiagnostics(notification))

        #expect(published.uri == "file:///Script.swift")
        #expect(published.version == 4)
        #expect(published.diagnostics.count == 1)
        #expect(published.diagnostics.first?.severity == .error)
        #expect(published.diagnostics.first?.code == "cannot-find-type")
        #expect(published.diagnostics.first?.span.end.character == 5)
    }

    @Test("ignores notifications for other methods")
    func ignoresOtherNotifications() throws {
        let notification = SourceKitLSPNotification(method: "window/logMessage",
                                                    params: try LSPJSON.data(["message": "hi"]))

        #expect(ScriptLanguageReplies.parseDiagnostics(notification) == nil)
    }
}
