import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Editor gutter and folding", .serialized)
@MainActor
struct GutterTests: GuavaUIComposeSerializedSuite {
    nonisolated private static let sample = "struct Example {\n    let name = \"Guava\"\n\n    func greet() {\n        print(name)\n    }\n    let other = 1\n}\nlet end = 2\n"
    private final class Harness: View {
        @State var text = TextBuffer(GutterTests.sample)
        @State var breakpoints = [TextBreakpoint(line: 4)]
        @State var regions = [TextFoldRegion(lines: 0...7), TextFoldRegion(lines: 3...5)]
        @State var collapsed: Set<Int> = []
        @State var width: Float = 720
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var enabled = true
        @State var code = true
        @State var dark = false
        @State var wraps = false
        @State var markerCalls = 0
        @State var completionCalls = 0
        @State var navigation = 0
        @State var target = 0
        var body: some View {
            var surface = UIEnvironment(); surface.input = input; surface.viewport.width = width
            return LayerRoot {
                Box(direction: .column, alignItems: .stretch) {
                    TextField(text: $text) { field in
                        field.layout.axis = .vertical; field.layout.wrapsLines = wraps
                        field.behavior.disabled = !enabled
                        field.codeEditing.showsLineNumbers = code
                        field.codeEditing.onRequestCompletion = { _, _ in self.completionCalls += 1 }
                        field.codeEditing.gutter.breakpoints = $breakpoints
                        field.codeEditing.gutter.markers = [
                            TextGutterMarker("run", line: 3, label: "Run greeting — 完整名称", icon: UIIcons.Editor.play) { self.markerCalls += 1 }
                        ]
                        field.codeEditing.folding.regions = regions
                        field.codeEditing.folding.collapsedLines = $collapsed
                        if navigation > 0 { field.navigation.caretRequestID = navigation; field.navigation.caretRequestIndex = target }
                    }.font(.monospaced(size: 15)).lineHeight(24).textFieldStyle(.editor).frame(height: 300)
                    Button("After editor") {}.accessibilityLabel("After editor")
                }.frame(width: width, height: 340)
            }.surfaceEnvironment(surface).textScaler(.init(scale)).appearance(dark ? .dark : .light)
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }; return [root] + root.children.flatMap { nodes($0) }
    }
    private func field(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
    }
    private func control(_ label: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.isFocusable && $0.accessibility?.label == label })
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<8 {
            graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 340)
            if let root = graph.tree.root { NodeRenderer().render(root: root, into: DrawList()) }
        }
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: h); settle(graph, h)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                            capture: context.pointerCapture, focusChain: context.focusChain)
                try work(h, graph, context, input)
            } }
        }
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
    }
    private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
    }

    @Test("Separate pointer lanes and a 44pt touch line menu retain names and finite geometry through the adaptive matrix")
    func geometry() throws {
        try scene { h, graph, _, _ in
            let original = try field(graph)
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] {
                        h.width = width; h.scale = scale; h.input = input; h.dark = dark; settle(graph, h)
                        let surface = try field(graph), session = try #require(surface.firstResource(TextGutterSession.self))
                        #expect(surface === original && surface.frame.width == CGFloat(width))
                        #expect(!session.controls.isEmpty && session.controls.count < 50)
                        for control in session.controls {
                            #expect(control.frame.minX >= 0 && control.frame.maxX <= surface.frame.width)
                            #expect(control.frame.minY >= 0 && control.frame.maxY <= surface.frame.height)
                            if input.contains(.touch) { #expect(control.frame.width >= 44 && control.frame.height >= 44) }
                        }
                        if input.contains(.touch) {
                            #expect(session.controls.contains { $0.kind == .combined })
                        } else {
                            #expect(session.controls.contains { $0.kind == .breakpoint })
                            #expect(session.controls.contains { $0.kind == .markers })
                            #expect(session.controls.contains { $0.kind == .fold })
                        }
                        #expect(h.text.stringValue == Self.sample && !graph.recomposer.hasPending)
                    }
                }
            } }
        }
    }

    @Test("Pointer breakpoint and marker actions preserve source/caret; folding hides visual rows and moves a hidden caret to its header")
    func pointerActions() throws {
        try scene { h, graph, context, input in
            let surface = try field(graph), session = try #require(surface.firstResource(TextGutterSession.self))
            let state = try #require(surface.attachments["__textfield_state"] as? TextField.FieldState)
            let before = state.selection.cursorIndex
            click(try control("Add breakpoint at line 2", graph), input); settle(graph, h)
            #expect(h.breakpoints.contains { $0.line == 1 } && state.selection.cursorIndex == before)
            click(try control("Remove breakpoint at line 2", graph), input); settle(graph, h)
            #expect(!h.breakpoints.contains { $0.line == 1 })
            click(try control("Run greeting — 完整名称", graph), input); settle(graph, h)
            #expect(h.markerCalls == 1 && h.text.stringValue == Self.sample)
            state.selection.cursorIndex = h.text.lineRange(forLine: 4).lowerBound
            click(try control("Collapse code at line 4", graph), input); settle(graph, h)
            #expect(h.collapsed == [3] && context.focusChain.focused === surface)
            #expect(h.text.lineIndex(forCharacterIndex: state.selection.cursorIndex) == 3)
            #expect(!session.controls.contains { $0.line == 4 || $0.line == 5 })
            #expect(try control("Expand code at line 4", graph).accessibility?.state.isExpanded == false)
            key(Scancode.arrowDown, input); settle(graph, h)
            #expect(h.text.lineIndex(forCharacterIndex: state.selection.cursorIndex) == 6)
            click(try control("Expand code at line 4", graph), input); settle(graph, h)
            #expect(h.collapsed.isEmpty && session.controls.contains { $0.line == 4 })
            #expect(h.text.stringValue == Self.sample)
        }
    }

    @Test("Keyboard, touch menus and assistive actions reach the same operations; hidden targets unfold on navigation")
    func equivalentInputs() throws {
        try scene { h, graph, context, input in
            let surface = try field(graph), state = try #require(surface.attachments["__textfield_state"] as? TextField.FieldState)
            context.focusChain.focus(surface)
            state.selection.cursorIndex = h.text.lineRange(forLine: 3).lowerBound
            key(Scancode.f9, input); settle(graph, h)
            #expect(h.breakpoints.contains { $0.line == 3 })
            key(Scancode.f9, input, modifiers: .lshift); settle(graph, h)
            #expect(h.breakpoints.first { $0.line == 3 }?.state == .disabled)
            key(Scancode.f9, input, modifiers: .lshift); settle(graph, h)
            #expect(h.breakpoints.first { $0.line == 3 }?.state == .enabled)
            key(Scancode.arrowLeft, input, modifiers: [.lgui, .lalt]); settle(graph, h)
            #expect(h.collapsed.contains(3))
            h.target = h.text.lineRange(forLine: 4).lowerBound; h.navigation += 1; settle(graph, h)
            #expect(h.collapsed.isEmpty && state.selection.cursorIndex == h.target)
            h.input = [.touch]; settle(graph, h)
            click(try control("Line 4 actions", graph), input); settle(graph, h)
            let remove = try control("Remove breakpoint at line 4", graph)
            remove.accessibilityActions.activate?(); settle(graph, h)
            #expect(!h.breakpoints.contains { $0.line == 3 })
            click(try control("Line 4 actions", graph), input); settle(graph, h)
            click(try control("Collapse code at line 4", graph), input); settle(graph, h)
            #expect(h.collapsed.contains(3) && h.text.stringValue == Self.sample)
        }
    }

    @Test("Gutter focus restoration does not request completion; subsequent typing still does")
    func gutterFocusAndCompletion() throws {
        try scene { h, graph, _, input in
            let surface = try field(graph), state = try #require(surface.attachments["__textfield_state"] as? TextField.FieldState)
            state.selection.cursorIndex = h.text.lineRange(forLine: 4).lowerBound + 13
            click(try control("Add breakpoint at line 2", graph), input); settle(graph, h)
            AnimatorScheduler.current.tick(deltaTime: 1); settle(graph, h)
            #expect(h.completionCalls == 0)
            input.dispatch(.textInput("x")); settle(graph, h)
            AnimatorScheduler.current.tick(deltaTime: 1); settle(graph, h)
            #expect(h.completionCalls == 1)
        }
    }

    @Test("Code configuration copies remain independent; IME previews do not rewrite folded source or expose stale actions")
    func configurationAndComposition() throws {
        let original = TextField(text: .constant(TextBuffer(Self.sample))) {
            $0.codeEditing.showsLineNumbers = true
            $0.codeEditing.folding.regions = [TextFoldRegion(lines: 0...7)]
        }
        var copy = original
        copy.codeEditing.folding.regions = []; copy.codeEditing.gutter.labels.addBreakpoint = { "断点 \($0)" }
        #expect(original.codeEditing.folding.regions.count == 1 && copy.codeEditing.folding.regions.isEmpty)
        #expect(original.codeEditing.gutter.labels.addBreakpoint(1) == "Add breakpoint at line 2")
        try scene { h, graph, context, input in
            click(try control("Collapse code at line 4", graph), input); settle(graph, h)
            let surface = try field(graph), session = try #require(surface.firstResource(TextGutterSession.self))
            let state = try #require(surface.attachments["__textfield_state"] as? TextField.FieldState)
            context.focusChain.focus(surface)
            state.selection.cursorIndex = h.text.lineRange(forLine: 8).upperBound
            input.dispatch(.textEditing(.init(text: "ni", start: 2, length: 0))); settle(graph, h)
            #expect(h.text.stringValue == Self.sample && state.composition.isActive && session.controls.isEmpty)
            input.dispatch(.textInput("你")); settle(graph, h)
            #expect(h.text.stringValue == Self.sample.replacingOccurrences(of: "let end = 2", with: "let end = 2你"))
            #expect(h.collapsed == [3] && !state.composition.isActive && !session.controls.isEmpty)
            key(Scancode.z, input, modifiers: .lgui); settle(graph, h)
            #expect(h.text.stringValue == Self.sample && h.collapsed == [3])
        }
    }

    @Test("Breakpoints and collapsed headers rebase on edits; stale disabled and unmounted actions cannot mutate state")
    func editingAndLifetime() throws {
        try scene { h, graph, _, input in
            click(try control("Collapse code at line 4", graph), input); settle(graph, h)
            h.text = h.text.insert("// heading\n", atCharacterIndex: 0); settle(graph, h)
            #expect(h.breakpoints.first?.line == 5 && h.collapsed == [4])
            let stale = try control("Add breakpoint at line 2", graph).accessibilityActions.activate
            h.enabled = false; settle(graph, h)
            let before = h.breakpoints; stale?(); settle(graph, h)
            #expect(h.breakpoints == before)
            h.enabled = true; h.code = false; settle(graph, h)
            stale?(); #expect(h.breakpoints == before)
            h.code = true; settle(graph, h)
            #expect(h.collapsed == [4])
            graph.install(root: EmptyView()); stale?(); #expect(h.breakpoints == before)
        }
    }

    @Test("A 200K-line collapsed range is skipped by the row index rather than shaped or copied")
    func largeFold() throws {
        let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let env = try #require(TextEnvironmentHolder.current)
        let buffer = TextBuffer((0..<200_000).map { "let value\($0) = \($0)" }.joined(separator: "\n"))
        let geometry = TextLineGeometry(font: .monospaced(size: 15), lineHeight: 24, letterSpacing: 0,
                                        atlas: ObjectIdentifier(env.atlas), width: .infinity, secure: false)
        let document = TextDocumentLayout(buffer: buffer, geometry: geometry)
        document.setHiddenLines([1..<199_999])
        let layout = document.visibleLayout(firstRow: 0, rowCount: 20, environment: env)
        #expect(document.index.rowCount == 2 && layout.lines.count == 2 && document.shapedLineCount == 2)
        #expect(document.index.location(atRow: 1).line == 199_999)
        document.setHiddenLines([])
        #expect(document.index.rowCount == 200_000)
    }

    @Test("Copy includes folded source; deleting a hidden boundary reveals it before editing, and undo restores the edit")
    func hiddenEditing() throws {
        try scene { h, graph, context, input in
            let surface = try field(graph), state = try #require(surface.attachments["__textfield_state"] as? TextField.FieldState)
            click(try control("Collapse code at line 4", graph), input); settle(graph, h)
            let oldWrite = ClipboardHolder.write; var copied = ""
            ClipboardHolder.write = { copied = $0 }; defer { ClipboardHolder.write = oldWrite }
            context.focusChain.focus(surface)
            key(Scancode.a, input, modifiers: .lgui); key(Scancode.c, input, modifiers: .lgui)
            #expect(copied == Self.sample && h.collapsed == [3])
            state.selection.anchor = nil; state.selection.cursorIndex = h.text.lineRange(forLine: 6).lowerBound
            key(Scancode.backspace, input); settle(graph, h)
            #expect(h.collapsed.isEmpty && h.text.stringValue == Self.sample)
            key(Scancode.backspace, input); settle(graph, h)
            #expect(h.text.stringValue != Self.sample)
            key(Scancode.z, input, modifiers: .lgui); settle(graph, h)
            #expect(h.text.stringValue == Self.sample)
        }
    }

    @Test("Caller-rebased annotations are accepted once, and one gutter Tab stop returns to editing with Escape")
    func controlledAnnotationsAndKeyboard() throws {
        try scene { h, graph, context, input in
            click(try control("Collapse code at line 4", graph), input); settle(graph, h)
            var annotations = TextEditorAnnotations()
            annotations.breakpoints = h.breakpoints; annotations.collapsedLines = h.collapsed
            let next = h.text.insert("// before\n", atCharacterIndex: 0)
            annotations.rebase(from: h.text, to: next)
            h.breakpoints = annotations.breakpoints; h.collapsed = annotations.collapsedLines; h.text = next
            settle(graph, h)
            #expect(h.breakpoints.first?.line == 5 && h.collapsed == [4])
            let surface = try field(graph)
            context.focusChain.focus(surface)
            key(Scancode.tab, input); settle(graph, h)
            #expect(context.focusChain.focused !== surface && context.focusChain.focused?.accessibility?.role == .button)
            key(Scancode.tab, input); settle(graph, h)
            #expect(context.focusChain.focused?.accessibility?.label == "After editor")
            context.focusChain.focus(try control("Add breakpoint at line 1", graph))
            key(Scancode.escape, input); settle(graph, h)
            #expect(context.focusChain.focused === surface)
        }
    }

    @Test("Line-start insertion uses right affinity; undo, identical reloads and pending parsers preserve document annotations")
    func anchorAffinityAndParserReadiness() {
        let original = TextBuffer(Self.sample), inserted = original.insert("// title\n", atCharacterIndex: 0)
        var annotations = TextEditorAnnotations()
        annotations.breakpoints = [TextBreakpoint(line: 0)]; annotations.collapsedLines = [0]
        annotations.rebase(from: original, to: inserted)
        #expect(annotations.breakpoints.first?.line == 1 && annotations.collapsedLines == [1])
        annotations.rebase(from: inserted, to: original)
        #expect(annotations.breakpoints.first?.line == 0 && annotations.collapsedLines == [0])
        annotations.rebase(from: original, to: TextBuffer(Self.sample))
        #expect(annotations.breakpoints.first?.line == 0 && annotations.collapsedLines == [0])
        var stored: Set<Int> = [0], options = TextEditorFolding()
        options.isReady = false; options.collapsedLines = Binding(get: { stored }, set: { stored = $0 })
        let folds = TextFoldSession(); folds.synchronize(options, buffer: original)
        #expect(stored == [0])
        options.regions = [TextFoldRegion(lines: 0...7)]; options.isReady = true
        folds.synchronize(options, buffer: original)
        #expect(folds.hiddenLines == [1..<8] && stored == [0])
    }

    @Test("Nested collapsed state survives an outer toggle; crossing and invalid ranges cannot corrupt the row projection")
    func nestedRegions() {
        var options = TextEditorFolding()
        options.regions = [.init(lines: -1...2), .init(lines: 0...7), .init(lines: 3...5),
                           .init(lines: 4...8), .init(lines: 7...20), .init(lines: 1...1)]
        let folds = TextFoldSession(); folds.synchronize(options, buffer: TextBuffer(Self.sample))
        #expect(Set(folds.regions.keys) == [0, 3])
        folds.toggle(3); folds.toggle(0)
        #expect(folds.hiddenLines == [1..<8])
        folds.toggle(0)
        #expect(folds.collapsed == [3] && folds.hiddenLines == [4..<6])
        #expect(folds.reveal(4) && folds.collapsed.isEmpty)
    }
}
