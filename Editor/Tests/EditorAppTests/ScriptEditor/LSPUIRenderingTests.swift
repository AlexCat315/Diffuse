import Foundation
import Testing
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
@testable import EditorApp

@Suite("Editor code UI integration", .serialized)
struct LSPUIRenderingTests {
    @Test("The production editor fills its viewport and accepts pointer focus")
    @MainActor
    func pointerFocus() throws {
        let context = PlatformInputContext(), portals = PortalStore()
        context.addScopedAmbient(PortalStoreAmbient(portals))
        try context.withCurrent {
            var source: TextBuffer = "let message = \"Guava\"\nlet upper = message."
            let original = source
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                ScriptCodeEditor(source: Binding(get: { source }, set: { source = $0 }),
                    hover: .constant(.hidden), caretLabel: .constant(""), onChange: { _ in },
                    onHover: { _ in }, onHoverEnd: {})
                    .flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
            })
            graph.computeLayout(width: 800, height: 600)
            let root = try #require(graph.tree.root)
            let hit = try #require(HitTester.hitTest(rootNode: root, point: CGPoint(x: 100, y: 100)))
            #expect(hit.node.accessibility?.role == .textField)
            #expect(hit.node.absoluteFrame.height > 500)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            let click = MouseButtonEvent(button: .left, x: 100, y: 100, clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(click)); dispatcher.dispatch(.mouseButtonUp(click))
            #expect(context.focusChain.focused === hit.node)
            dispatcher.dispatch(.textInput("z"))
            #expect(source.characterCount == original.characterCount + 1 && source.stringValue.contains("z"))
            context.focusChain.clear()
            hit.node.accessibilityActions.activate?()
            #expect(context.focusChain.focused === hit.node)
            graph.install(root: EmptyView())
        }
    }
    @Test("LSP ranges map Unicode diagnostics to UTF-8 and preserve the cached index")
    func diagnostics() {
        let buffer: TextBuffer = "let value = \"😀\"\nlet 中文 = missing"
        let diagnostic = ScriptLanguageDiagnostic(severity: .error, startLine: 0, startCharacter: 13,
            endLine: 0, endCharacter: 15, message: "Emoji diagnostic", code: nil)
        let cache = ScriptCodeEditorDiagnostics()
        let mapped = cache.synchronize(buffer: buffer, diagnostics: [diagnostic])
        #expect(mapped.overlapping(13..<17).first?.utf8Range == 13..<17)
        #expect(cache.synchronize(buffer: buffer, diagnostics: [diagnostic]) == mapped)
        #expect(cache.synchronize(buffer: buffer, diagnostics: []).overlapping(0..<100).isEmpty)
    }
    @Test("Completion preserves both edit endpoints, additional import edits and fallback snippet text")
    func completionEdits() throws {
        let buffer: TextBuffer = "let 中文 = priTail"
        let request = TextCompletionRequest(buffer: buffer, caretIndex: 12)
        let data = Data(#"{"items":[{"label":"print","kind":3,"insertTextFormat":2,"filterText":"print","textEdit":{"replace":{"start":{"line":0,"character":9},"end":{"line":0,"character":16}},"insert":{"start":{"line":0,"character":9},"end":{"line":0,"character":12}},"newText":"print(${1:value})$0"},"additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import Foundation\n"}]}]}"#.utf8)
        let source = ScriptLanguageReplies.parseCompletion(data)
        let item = try #require(ScriptCompletionConversion.items(source, for: request).first)
        #expect(item.insertText == "print(value)" && item.filterText == "print")
        #expect(item.replacement == 9..<16)
        #expect(item.additionalEdits == [.init(range: 0..<0, text: "import Foundation\n")])
        #expect(ScriptCompletionConversion.plainSnippet("call(${1|first,second|}, ${2:arg})$0") == "call(first, arg)")
    }
    @Test("A 200K-line syntax worker leaves the caller free and drops superseded roots")
    @MainActor
    func asynchronousSyntax() async throws {
        let session = ScriptSyntaxSession()
        let original = TextBuffer(String(repeating: "let value = 42\n", count: 200_000))
        let start = Date()
        session.request(original)
        #expect(Date().timeIntervalSince(start) < 0.1)
        var next = original
        let middle = next.lineRange(forLine: 100_000).upperBound - 1
        for _ in 0..<50 { next = next.insert("1", atCharacterIndex: middle); session.request(next) }
        let deadline = Date().addingTimeInterval(15)
        while session.parsedBuffer != next, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.parsedBuffer == next && session.failure == nil)
        #expect(session.color(atUTF8Offset: next.utf8Offset(forCharacterIndex: middle), light: false) != nil)
        // Undo uses the original root while parsing catches up independently.
        session.request(original)
        while session.parsedBuffer != original, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.parsedBuffer == original)
    }
}
