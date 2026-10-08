import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Rope TextField integration", .serialized)
struct TextFieldLargeDocumentTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    @Test("Long code rows reveal the caret horizontally, preserve the gutter and reset after undo")
    func horizontalCaretReveal() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = prior }
        let context = PlatformInputContext()
        try context.withCurrent {
            var buffer = TextBuffer(String(repeating: "let value = 1\n", count: 200_000))
            let original = buffer, middle = buffer.lineRange(forLine: 100_000).upperBound
            let field = TextField(text: Binding(get: { buffer }, set: { buffer = $0 })) { input in
                input.layout.axis = .vertical; input.layout.wrapsLines = false
                input.codeEditing.showsLineNumbers = true
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = middle
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: field.frame(width: 320, height: 160).font(.mono))
            graph.computeLayout(width: 320, height: 160)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            let handlers = context.interactions.handlers(for: node)
            _ = handlers.text?(String(repeating: "x", count: 200), .target)
            let draws = DrawList(); node.draw?(draws, .zero)
            #expect(state.scroll.horizontal.offset > 500)
            let area = try #require(field.committedTextInputArea(node: node, state: state, absoluteOrigin: .zero, isFocused: true))
            #expect(area.x > 50 && area.x < 310)
            let engine = TextField.LayoutEngine(textField: field)
            #expect(engine.characterIndex(atWindowPoint: CGPoint(x: CGFloat(area.x), y: CGFloat(area.y + 2)), state: state, node: node) == middle + 200)
            #expect(draws.currentClip == nil)
            let document = try #require(node.attachments["__textfield_document_layout"] as? TextDocumentLayout)
            #expect(document.shapedLineCount < 25)
            let shapes = document.shapedLineCount
            let priorX = state.scroll.horizontal.offset
            _ = handlers.wheel?(MouseWheelEvent(x: 2, y: 0, mouseX: 200, mouseY: 120), .target)
            node.draw?(DrawList(), .zero)
            #expect(state.scroll.horizontal.offset < priorX && document.shapedLineCount == shapes)
            field.moveCursor(to: buffer.lineRange(forLine: 100_000).lowerBound, extendSelection: false, state: state)
            node.draw?(DrawList(), .zero)
            #expect(state.scroll.horizontal.offset == 0)
            _ = handlers.key?(KeyEvent(scancode: Scancode.z, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
            node.draw?(DrawList(), .zero)
            #expect(buffer == original && state.scroll.horizontal.offset == 0 && state.scroll.horizontal.maximum == 0)
            graph.install(root: EmptyView())
        }
    } }
    @Test("200K-line input, render, IME and undo operate on a bounded window")
    func middleEditing() throws { try GlobalTestLock.locked {
        let oldEnvironment = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = oldEnvironment }
        let context = PlatformInputContext()
        try context.withCurrent {
            var buffer = TextBuffer(String(repeating: "let example = 123\n", count: 200_000))
            let original = buffer
            let middle = buffer.lineRange(forLine: 100_000).upperBound
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: TextField(text: Binding(get: { buffer }, set: { buffer = $0 })) { input in
                input.layout.axis = .vertical; input.layout.wrapsLines = false
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = middle
                input.codeEditing.showsLineNumbers = true
            }.frame(width: 600, height: 240).font(.mono))
            graph.recomposer.commitAll()
            graph.computeLayout(width: 600, height: 240)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            node.draw?(DrawList(), .zero)
            let layout = try #require(node.attachments["__textfield_document_layout"] as? TextDocumentLayout)
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            #expect(state.scroll.offsetY > 1_000_000)
            #expect(layout.shapedLineCount < 30 && layout.shapedUTF8Count < 600)
            let initialShapes = layout.shapedLineCount
            for _ in 0..<100 { node.draw?(DrawList(), .zero) }
            #expect(layout.shapedLineCount == initialShapes)
            let handlers = context.interactions.handlers(for: node)
            let start = Date()
            for _ in 0..<100 {
                _ = handlers.text?("a", .target); node.draw?(DrawList(), .zero)
            }
            #expect(layout.shapedLineCount == initialShapes + 100)
            #expect(Date().timeIntervalSince(start) < 10)
            #expect(buffer.substring(characterRange: middle..<(middle + 100)) == String(repeating: "a", count: 100))
            #expect(state.transaction.history.undo()?.buffer == original)
            let committed = buffer
            _ = handlers.editing?(TextEditingEvent(text: "你", start: 1, length: 0), .target)
            node.draw?(DrawList(), .zero)
            let previewShapes = layout.shapedLineCount
            #expect(state.composition.isActive)
            let preview = try #require(state.renderDraft.preview)
            #expect(preview.buffer != committed)
            for _ in 0..<50 { node.draw?(DrawList(), .zero) }
            #expect(buffer == committed && layout.shapedLineCount == previewShapes)
            #expect(state.renderDraft.preview?.buffer == preview.buffer)
        }
    } }
    @Test("A combining insertion puts the caret at its Rope grapheme endpoint")
    func joiningGraphemes() { GlobalTestLock.locked {
        let context = PlatformInputContext()
        context.withCurrent {
            var buffer: TextBuffer = "eZ"
            let field = TextField(text: Binding(get: { buffer }, set: { buffer = $0 }))
            let state = TextField.FieldState(); state.selection.cursorIndex = 1
            field.insertReplacingSelection("\u{301}", state: state)
            #expect(buffer.stringValue == "e\u{301}Z" && buffer.characterCount == 2)
            #expect(state.selection.cursorIndex == 1)
            field.insertReplacingSelection("!", state: state)
            #expect(buffer.stringValue == "e\u{301}!Z")
            buffer = "🇨!🇳Z"
            state.selection.anchor = 1; state.selection.cursorIndex = 2
            field.deleteSelection(state: state)
            #expect(buffer.stringValue == "🇨🇳Z" && buffer.characterCount == 2)
            #expect(state.selection.cursorIndex == 1)
        }
    } }
}
