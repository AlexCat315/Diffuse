import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Editor snippets and long lines", .serialized)
@MainActor
struct SnippetTests: GuavaUIComposeSerializedSuite {
    @Test("Snippet syntax expands placeholders, choices, escapes and the final stop")
    func parse() throws {
        let snippet = TextSnippet("for ${1:item} in ${2|items,list|} {\n\t$0\n} \\$x ${TM_FILENAME:file}")
        #expect(snippet.text == "for item in items {\n\t\n} $x file")
        #expect(snippet.stops.map(\.number) == [1, 2, 0])
        #expect(snippet.stops[0].range == 4..<8)
        #expect(snippet.stops[1].range == 12..<17)
        #expect(snippet.stops[2].range == 21..<21)
        let implicit = TextSnippet("print($1)")
        #expect(implicit.text == "print()")
        #expect(implicit.stops.map(\.range) == [6..<6, 7..<7])
        let nested = TextSnippet("${1:outer ${2:inner}}")
        #expect(nested.text == "outer inner")
        #expect(nested.stops[0].range == 0..<11 && nested.stops[1].range == 6..<11)
    }

    @Test("Tab visits stops in order, edits inside a stop move later stops, and the final stop ends the session")
    func session() throws {
        let session = TextSnippetSession()
        let snippet = TextSnippet("f(${1:a}, ${2:b})$0")
        var buffer = TextBuffer("x = " + snippet.text)
        let first = session.start(snippet, at: 4, in: buffer)
        #expect(first == 6..<7)
        // Typing "alpha" over the first placeholder.
        buffer = buffer.replace(characterRange: 6..<7, with: "alpha")
        let tab = KeyEvent(scancode: Scancode.tab, keycode: 0, modifiers: [], isRepeat: false)
        #expect(session.command(for: tab, buffer: buffer) == .some(13..<14))
        let back = KeyEvent(scancode: Scancode.tab, keycode: 0, modifiers: .shift, isRepeat: false)
        #expect(session.command(for: back, buffer: buffer) == .some(6..<11))
        #expect(session.command(for: tab, buffer: buffer) == .some(13..<14))
        #expect(session.command(for: tab, buffer: buffer) == .some(15..<15))
        #expect(!session.isActive)
        // An edit outside the current stop ends the session without consuming Tab.
        _ = session.start(snippet, at: 4, in: buffer)
        let elsewhere = buffer.replace(characterRange: 0..<1, with: "y")
        #expect(session.command(for: tab, buffer: elsewhere) == nil)
        #expect(!session.isActive)
    }

    @Test("Accepting a snippet completion selects the first placeholder and Tab moves on")
    func completionIntegration() throws {
        try InteractiveScene.run(width: 600, height: 200) { scene in
            var text: TextBuffer = "fu"
            var deliver: (@MainActor @Sendable ([TextCompletionItem]) -> Void)?
            scene.install(TextField(text: Binding(get: { text }, set: { text = $0 })) { input in
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = 2
                input.codeEditing.onRequestCompletion = { _, reply in deliver = reply }
            }.frame(width: 500, height: 40))
            let node = try #require(scene.first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            AnimatorScheduler.current.tick(deltaTime: 0.31)
            var item = TextCompletionItem(id: "fn", label: "func", insertText: "func ${1:name}($2) {}")
            item.replacement = 0..<2
            item.insertTextFormat = .snippet
            let reply = try #require(deliver); reply([item])
            let completion = try #require(node.firstResource(TextCompletionSession.self))
            _ = completion.handleKey(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false))
            #expect(text.stringValue == "func name() {}")
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            #expect(state.selection.anchor == 5 && state.selection.cursorIndex == 9)
            #expect(node.firstResource(TextSnippetSession.self)?.isActive == true)
            scene.focus.focus(node)
            scene.key(Scancode.tab)
            #expect(state.selection.anchor == nil && state.selection.cursorIndex == 10)
            scene.dispatcher.dispatch(.textInput("x")); scene.settle()
            #expect(text.stringValue == "func name(x) {}")
        }
    }

    @Test("A very long unwrapped line shapes in segments with monotonic glyphs and exact carets")
    func longLine() throws {
        GlobalTestLock.locked {
            let env = TestTextEnvironmentFactory.make()
            let line = String(repeating: "abcdefghij ", count: 3_000)
            let geometry = TextLineGeometry(font: env.defaultFont, lineHeight: 20, letterSpacing: 0,
                                            atlas: ObjectIdentifier(env.atlas), width: .infinity, secure: false)
            let document = TextDocumentLayout(buffer: TextBuffer(line), geometry: geometry)
            let measured = document.measuredLine(0, environment: env)
            #expect(measured.rows.count == 1)
            let glyphs = measured.rows[0].glyphs
            #expect(glyphs.count >= line.count - 3_000)
            #expect(zip(glyphs, glyphs.dropFirst()).allSatisfy { $0.x <= $1.x })
            #expect(glyphs.last.map { Int($0.cluster) } ?? 0 >= line.utf8.count - 2)
            let whole = env.cachedLayout(text: String(line.prefix(110)), font: env.defaultFont, lineHeight: 20)
            #expect(abs(document.caret(atCharacter: 110, environment: env).x - whole.lines[0].width) < 2)
            #expect(document.character(atRow: 0, x: measured.rows[0].width + 10, environment: env) == line.count)
        }
    }

    @Test("Horizontal culling keeps only glyphs near the viewport of a long row")
    func culling() throws {
        let glyphs = (0..<2_000).map { PositionedGlyph(glyphID: 1, fontID: 0, cluster: UInt32($0), x: Float($0) * 10, y: 0, atlasInfo: nil) }
        let layout = TextLayoutResult(lines: [TextLine(glyphs: glyphs, baselineY: 10, topY: 0, width: 20_000, startCluster: 0, endCluster: 2_000)],
                                      totalWidth: 20_000, totalHeight: 20)
        let engine = TextField.LayoutEngine(textField: TextField(text: .constant(TextBuffer(""))))
        let culled = engine.visibleLayout(from: layout, scrollOffsetY: 0, visibleHeight: 20, lineHeight: 20, visibleX: 5_000..<5_300)
        let kept = culled.lines[0].glyphs
        #expect(kept.count < 100)
        #expect((kept.first?.x ?? 0) <= 5_000 && (kept.last?.x ?? 0) >= 5_300)
        #expect(culled.lines[0].width == 20_000)
    }
}
