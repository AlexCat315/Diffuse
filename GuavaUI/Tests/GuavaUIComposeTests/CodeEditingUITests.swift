import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Code editing UI", .serialized)
@MainActor
struct CodeEditingUITests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    @Test("Keyboard hover uses the scrolled visible caret and preserves read-only text")
    func keyboardHover() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = prior }
        let context = PlatformInputContext()
        try context.withCurrent {
            let buffer = TextBuffer("let " + String(repeating: "a", count: 150))
            var requested: TextFieldHoverAnchor?
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: TextField(text: .constant(buffer)) { input in
                input.behavior.readOnly = true
                input.codeEditing.onRequestHover = { requested = $0 }
            }.frame(width: 300, height: 40))
            graph.computeLayout(width: 300, height: 40)
            let node = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .textField })
            context.focusChain.focus(node)
            node.draw?(DrawList(), .zero)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.f1, keycode: 0, modifiers: [], isRepeat: false)))
            let anchor = try #require(requested)
            #expect(anchor.characterIndex == buffer.characterCount && anchor.windowX > 100 && anchor.windowX < 300)
            #expect(anchor.windowY > 0 && anchor.windowY < 40)
            #expect(context.focusChain.focused === node)
            graph.install(root: EmptyView())
        }
    } }
    @Test("Completion selection spans the popup width and detail columns align")
    func completionRowGeometry() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = prior }
        var first = TextCompletionItem(id: "upper", label: "uppercased()", insertText: "uppercased()")
        first.detail = "String"
        var second = TextCompletionItem(id: "locale", label: "uppercased(with: Locale?)", insertText: "uppercased(with: )")
        second.detail = "String"
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: CompletionPopover(items: [first, second], selectedIndex: 0, onAccept: { _ in }))
        graph.computeLayout(width: 380, height: 80)
        let rows = nodes(graph.tree.root).filter { $0.accessibility?.role == .listItem }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { abs($0.absoluteFrame.width - 374) < 0.5 })
        let labels = rows.map { nodes($0).filter { $0.accessibility?.label == "String" }.last }
        #expect(labels.count == 2)
        let firstLabel = try #require(labels[0]), secondLabel = try #require(labels[1])
        #expect(firstLabel.absoluteFrame.maxX == secondLabel.absoluteFrame.maxX)
        graph.install(root: EmptyView())
    } }
    @Test("Diagnostics select overlapping visible rows, cluster spans and empty positions")
    func diagnosticGeometry() throws { try GlobalTestLock.locked {
        let env = TestTextEnvironmentFactory.make()
        let buffer: TextBuffer = "let emoji = 😀\n\nlet tail = 1"
        let document = TextDocumentLayout(buffer: buffer, geometry: TextLineGeometry(font: .system(size: 14), lineHeight: 20,
            letterSpacing: 0, atlas: ObjectIdentifier(env.atlas), width: .infinity, secure: false))
        let window = document.visibleLayout(firstRow: 0, rowCount: 3, environment: env)
        let emoji = buffer.utf8Offset(forCharacterIndex: 12)
        let blank = buffer.utf8Offset(forCharacterIndex: buffer.lineRange(forLine: 1).lowerBound)
        let values = TextDiagnostics([
            TextDiagnostic(utf8Range: emoji..<(emoji + 4), severity: .error, message: "Emoji"),
            TextDiagnostic(utf8Range: blank..<blank, severity: .warning, message: "Blank"),
            TextDiagnostic(utf8Range: 0..<10, severity: .information, message: "Declaration"),
            TextDiagnostic(utf8Range: 1_000_000..<1_000_100, severity: .error, message: "Offscreen")
        ])
        let segments = TextDiagnosticGeometry.segments(in: window, diagnostics: values, lineHeight: 20)
        #expect(segments.count == 3)
        let emojiSpan = try #require(segments.first { $0.diagnostic.message == "Emoji" })
        #expect(emojiSpan.x > 0 && emojiSpan.width >= 6 && emojiSpan.baselineY == 18)
        #expect(segments.first { $0.diagnostic.message == "Blank" }?.baselineY == 38)
        let list = DrawList()
        TextDiagnosticGeometry.draw(segments, origin: (10, 10), opacity: 1, theme: .defaultDark, list: list)
        #expect(!list.vertices.isEmpty)
        #expect(list.vertices.allSatisfy { $0.posY >= 27 && $0.posY <= 50 })
        #expect(values.overlapping(emoji..<(emoji + 1)).map(\.message) == ["Emoji"])
    } }

    @Test("Completion debounce, prefix filtering, arrow selection, Tab, Escape and undo")
    func completionInteraction() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext(), scheduler = AnimatorScheduler()
        let portals = PortalStore(); context.addScopedAmbient(PortalStoreAmbient(portals))
        let priorEnvironment = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = priorEnvironment }
        var buffer: TextBuffer = "pri"
        var replies: [(@MainActor @Sendable ([TextCompletionItem]) -> Void)] = []
        var requests: [TextCompletionRequest] = []
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let field = TextField(text: Binding(get: { buffer }, set: { buffer = $0 })) { input in
            input.codeEditing.onRequestCompletion = { request, reply in requests.append(request); replies.append(reply) }
        }
        let node: Node = try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            graph.install(root: field.frame(width: 500, height: 40))
            graph.computeLayout(width: 500, height: 40)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            context.focusChain.focus(node)
            scheduler.tick(deltaTime: 0.29); #expect(requests.isEmpty)
            scheduler.tick(deltaTime: 0.02); #expect(requests.count == 1)
            return node
        } }
        let session = try #require(node.firstResource(TextCompletionSession.self))
        let firstReply = try #require(replies.first)
        firstReply([.init(id: "print", label: "print", insertText: "print()"),
                    .init(id: "private", label: "private", insertText: "private "),
                    .init(id: "other", label: "other", insertText: "other")])
        #expect(session.items.map(\.label) == ["print", "private"])
        #expect(portals.entries.count == 1)
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            let handlers = context.interactions.handlers(for: node)
            _ = handlers.key?(KeyEvent(scancode: Scancode.arrowDown, keycode: 0, modifiers: [], isRepeat: false), .target)
            #expect(session.selectedIndex == 1)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.tab, keycode: 0, modifiers: [], isRepeat: false)))
            #expect(buffer.stringValue == "private ")
            #expect(portals.entries.isEmpty && context.focusChain.focused === node)
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            #expect(state.transaction.history.undo()?.buffer.stringValue == "pri")
            _ = handlers.text?("x", .target)
            scheduler.tick(deltaTime: 0.31)
            #expect(requests.count == 2)
            let late = try #require(replies.last)
            late([.init(id: "x", label: "x", insertText: "x")])
            #expect(portals.entries.count == 1)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.escape, keycode: 0, modifiers: [], isRepeat: false)))
            #expect(portals.entries.isEmpty && buffer.stringValue == "private x")
            session.activity(explicit: true)
            let blurred = try #require(replies.last)
            context.focusChain.clear()
            blurred([.init(id: "x", label: "x", insertText: "x")])
            #expect(portals.entries.isEmpty && session.items.isEmpty)
        } }
        graph.install(root: EmptyView())
    } }
    @Test("Retained completions rebase prefix, suffix and import ranges across Unicode edits")
    func completionRangesFollowPrefix() throws { try GlobalTestLock.locked {
        let old: TextBuffer = "😀\npriTail\nend"
        let request = TextCompletionRequest(buffer: old, caretIndex: 5)
        var item = TextCompletionItem(id: "print", label: "print", insertText: "print()")
        item.replacement = 2..<9
        item.additionalEdits = [.init(range: 0..<0, text: "import Foundation\n"), .init(range: 10..<13, text: "finish")]
        let typed = old.insert("n", atCharacterIndex: 5)
        let next = TextCompletionRequest(buffer: typed, caretIndex: 6)
        let moved = try #require(TextCompletionRebase.candidates([item], from: request, to: next).first)
        #expect(moved.replacement == 2..<10)
        #expect(moved.additionalEdits.map(\.range) == [0..<0, 11..<14])
        let deleted = typed.delete(characterRange: 5..<6)
        let restored = try #require(TextCompletionRebase.candidates([moved], from: next,
            to: TextCompletionRequest(buffer: deleted, caretIndex: 5)).first)
        #expect(restored == item)
        let unrelated = typed.insert("!", atCharacterIndex: 0)
        #expect(TextCompletionRebase.candidates([moved], from: next,
            to: TextCompletionRequest(buffer: unrelated, caretIndex: 7)).isEmpty)
        let popover = CompletionPopover(items: [item], selectedIndex: 900, onAccept: { _ in })
        #expect(popover.selectedIndex == 0)
    } }
    @Test("Coordinate tooltips fit at the viewport corner and unregister on unmount")
    func coordinateTooltip() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        let portals = PortalStore(); context.addScopedAmbient(PortalStoreAmbient(portals))
        try context.withCurrent {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                Tooltip(anchor: .range(CGRect(x: 390, y: 280, width: 10, height: 15)), configure: { $0.maxWidth = 240 }) {
                    Text("A diagnostic message").padding(10).background(.surfaceFloating)
                }
            })
            graph.recomposer.commitAll(); graph.computeLayout(width: 400, height: 300)
            let id = try #require(portals.entries.first?.id)
            let frame = try #require(portals.frame(id))
            #expect(frame.minX >= 6 && frame.maxX <= 394 && frame.maxY <= 294)
            #expect(frame.maxY <= 280)
            graph.install(root: EmptyView())
            #expect(portals.entries.isEmpty)
        }
    } }

    @Test("Completion replaces the suffix and inserts an import as one undo step")
    func additionalCompletionEdits() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext(), scheduler = AnimatorScheduler(), portals = PortalStore()
        context.addScopedAmbient(PortalStoreAmbient(portals))
        var buffer: TextBuffer = "priTail"
        let original = buffer
        var deliver: (@MainActor @Sendable ([TextCompletionItem]) -> Void)?
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: TextField(text: Binding(get: { buffer }, set: { buffer = $0 })) { input in
                input.navigation.caretRequestID = 1; input.navigation.caretRequestIndex = 3
                input.codeEditing.onRequestCompletion = { _, reply in deliver = reply }
            })
            graph.computeLayout(width: 500, height: 40)
            let node = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            scheduler.tick(deltaTime: 0.31)
            var item = TextCompletionItem(id: "print", label: "print", insertText: "print(value)")
            item.replacement = 0..<7
            item.additionalEdits = [.init(range: 0..<0, text: "import Foundation\n")]
            let reply = try #require(deliver); reply([item])
            let session = try #require(node.firstResource(TextCompletionSession.self))
            #expect(session.items.count == 1)
            _ = session.handleKey(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false))
            #expect(buffer.stringValue == "import Foundation\nprint(value)")
            let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
            #expect(state.selection.cursorIndex == buffer.characterCount)
            #expect(state.transaction.history.undo()?.buffer == original)
            #expect(state.transaction.history.canUndo == false)
            graph.install(root: EmptyView())
        } }
    } }
}
