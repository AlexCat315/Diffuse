import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("TextField line and page navigation", .serialized)
struct TextFieldNavigationTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    private func key(_ code: UInt32, _ modifiers: KeyModifiers = []) -> KeyEvent {
        KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)
    }

    #if canImport(CoreText)
    @Test("a joined color emoji renders, advances the caret and deletes as one character")
    func colorEmojiCaret() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current
        let env = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName, rasterScale: 2)
        TextEnvironmentHolder.current = env
        defer { TextEnvironmentHolder.current = prior }
        let context = PlatformInputContext()
        try context.withCurrent {
            var buffer: TextBuffer = "A👩🏽‍💻中🙂B"
            let original = buffer
            let field = TextField(text: Binding(get: { buffer }, set: { buffer = $0 })) { input in
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = 2
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: field.frame(width: 300, height: 36)); graph.computeLayout(width: 300, height: 36)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            let handler = try #require(context.interactions.handlers(for: node).key)
            let list = DrawList(); node.draw?(list, .zero)
            #expect(list.batches.contains { $0.textureID == TextureID(1).colorGlyphAtlasID })
            let after = try #require(field.committedTextInputArea(node: node, state: state, absoluteOrigin: .zero, isFocused: true))
            _ = handler(key(Scancode.arrowLeft), .target)
            #expect(state.selection.cursorIndex == 1)
            let before = try #require(field.committedTextInputArea(node: node, state: state, absoluteOrigin: .zero, isFocused: true))
            #expect(after.x - before.x > 12 && after.y == before.y)
            _ = handler(key(Scancode.arrowRight), .target)
            _ = handler(key(Scancode.backspace), .target)
            #expect(buffer.stringValue == "A中🙂B" && state.selection.cursorIndex == 1)
            _ = handler(key(Scancode.z, [.lgui]), .target)
            #expect(buffer == original && state.selection.cursorIndex == 2)
            graph.install(root: EmptyView())
        }
    } }
    #endif

    @Test("Line commands preserve preceding CRLF and Unicode lines, while document commands cross them")
    func logicalLines() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current; TextEnvironmentHolder.current = nil
        defer { TextEnvironmentHolder.current = prior }
        let context = PlatformInputContext()
        try context.withCurrent {
            var buffer: TextBuffer = "first\r\nAé👩🏽‍💻中Z\r\nlast"
            let original = buffer, range = buffer.lineRange(forLine: 1)
            let field = TextField(text: Binding(get: { buffer }, set: { buffer = $0 })) { input in
                input.layout.axis = .vertical; input.layout.wrapsLines = false
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = range.lowerBound + 2
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer()); graph.install(root: field)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            let handler = try #require(context.interactions.handlers(for: node).key)
            _ = handler(key(Scancode.home), .target)
            #expect(state.selection.cursorIndex == range.lowerBound)
            _ = handler(key(Scancode.end, [.lshift]), .target)
            #expect(field.selectionRange(state) == range)
            _ = handler(key(Scancode.arrowLeft, [.lgui]), .target)
            #expect(state.selection.cursorIndex == range.lowerBound && state.selection.anchor == nil)
            _ = handler(key(Scancode.arrowRight, [.lgui]), .target)
            _ = handler(key(Scancode.backspace, [.lgui]), .target)
            #expect(buffer.stringValue == "first\r\n\r\nlast")
            _ = handler(key(Scancode.z, [.lgui]), .target)
            #expect(buffer == original)
            _ = handler(key(Scancode.home, [.lctrl]), .target)
            #expect(state.selection.cursorIndex == 0)
            _ = handler(key(Scancode.end, [.lctrl]), .target)
            #expect(state.selection.cursorIndex == buffer.characterCount)
            _ = handler(key(Scancode.arrowUp, [.lgui]), .target)
            #expect(state.selection.cursorIndex == 0)
            _ = handler(key(Scancode.arrowDown, [.lgui, .lshift]), .target)
            #expect(field.selectionRange(state) == 0..<buffer.characterCount)
            graph.install(root: EmptyView())
        }
    } }

    @Test("Soft-wrap End stays on its displayed row for IME, Home and vertical motion")
    func wrappedRowAffinity() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current; let env = TestTextEnvironmentFactory.make()
        TextEnvironmentHolder.current = env; defer { TextEnvironmentHolder.current = prior }
        let context = PlatformInputContext()
        try context.withCurrent {
            let buffer = TextBuffer(String(repeating: "abcdefghij", count: 12))
            let field = TextField(text: .constant(buffer)) { input in
                input.layout.axis = .vertical; input.behavior.readOnly = true
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = 2
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: field.frame(width: 120, height: 140)); graph.computeLayout(width: 120, height: 140)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            let handler = try #require(context.interactions.handlers(for: node).key)
            let document = field.layoutEngine(for: node).interactiveDocument(in: buffer, node: node, env: env)
            let rowEnd = document.character(atRow: 0, x: .infinity, environment: env)
            #expect(rowEnd > 2 && rowEnd < buffer.characterCount)
            _ = handler(key(Scancode.end), .target)
            #expect(state.selection.cursorIndex == rowEnd && state.selection.lineEndAffinity)
            let area = try #require(field.committedTextInputArea(node: node, state: state, absoluteOrigin: .zero, isFocused: true))
            #expect(area.y < 20 && area.x > 70)
            _ = handler(key(Scancode.home), .target)
            #expect(state.selection.cursorIndex == 0)
            _ = handler(key(Scancode.end), .target)
            _ = handler(key(Scancode.arrowDown), .target)
            #expect(document.caret(atCharacter: state.selection.cursorIndex,
                lineEndAffinity: state.selection.lineEndAffinity, environment: env).row == 1)
            _ = handler(key(Scancode.arrowUp), .target)
            #expect(state.selection.cursorIndex == rowEnd)
            #expect(document.caret(atCharacter: state.selection.cursorIndex,
                lineEndAffinity: state.selection.lineEndAffinity, environment: env).row == 0)
            graph.install(root: EmptyView())
        }
    } }

    @Test("200K-line page moves preserve a preferred column and shape a bounded viewport")
    func pageNavigation() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current; let env = TestTextEnvironmentFactory.make()
        TextEnvironmentHolder.current = env; defer { TextEnvironmentHolder.current = prior }
        let context = PlatformInputContext()
        try context.withCurrent {
            let buffer = TextBuffer(String(repeating: "0123456789\n", count: 200_000))
            let middle = buffer.characterIndex(forLine: 100_000, character: 7)
            let field = TextField(text: .constant(buffer)) { input in
                input.layout.axis = .vertical; input.layout.wrapsLines = false; input.behavior.readOnly = true
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = middle
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: field.frame(width: 400, height: 160)); graph.computeLayout(width: 400, height: 160)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            let handler = try #require(context.interactions.handlers(for: node).key)
            _ = handler(key(Scancode.pageDown, [.lshift]), .target)
            let after = buffer.lineAndColumn(forCharacterIndex: state.selection.cursorIndex)
            #expect(after.line > 100_001 && after.line < 100_020 && after.column == 7)
            #expect(state.selection.anchor == middle)
            _ = handler(key(Scancode.pageUp), .target)
            #expect(state.selection.cursorIndex == middle && state.selection.anchor == nil)
            node.draw?(DrawList(), .zero)
            let document = try #require(node.attachments["__textfield_document_layout"] as? TextDocumentLayout)
            #expect(document.shapedLineCount < 25 && document.shapedUTF8Count < 300)
            graph.install(root: EmptyView())
        }
    } }
}
