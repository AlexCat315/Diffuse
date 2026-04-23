import Testing
import CoreGraphics
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 6.4b TextField", .serialized)
struct TextFieldTests: GuavaUIComposeSerializedSuite {

    private func makeRig() -> (
        registry: InteractionRegistry,
        focus: FocusChain,
        tree: NodeTree,
        graph: ViewGraph,
        store: TextStore
    ) {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = nil  // primitive must not crash without env

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        return (registry, focus, tree, graph, TextStore())
    }

    final class TextStore {
        var value: String = ""
    }

    private func makeBinding(_ store: TextStore) -> Binding<String> {
        Binding(get: { store.value }, set: { store.value = $0 })
    }

    private func fieldNode(in root: Node?) -> Node {
        guard let node = firstNode(in: root, where: { $0.attachments[TextField.surfaceMarkerKey] != nil }) else {
            fatalError("no TextField surface found")
        }
        return node
    }

    private func firstNode(in root: Node?, where predicate: (Node) -> Bool) -> Node? {
        guard let root else { return nil }
        if predicate(root) { return root }
        for child in root.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    final class TextFieldInteractionProbe {
        var focusedStates: [Bool] = []
        var editingStates: [Bool] = []
    }

    struct ProbingTextFieldStyle: TextFieldStyle {
        let probe: TextFieldInteractionProbe

        func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
            probe.focusedStates.append(configuration.isFocused)
            probe.editingStates.append(configuration.isEditing)
            return configuration.content
        }
    }

    @Test("textInput inserts characters at the cursor")
    func textInputInserts() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.graph.install(root:
            TextField("placeholder", text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        let textHandler = rig.registry.handlers(for: node).text!
        _ = textHandler("h", .target)
        _ = textHandler("i", .target)
        #expect(rig.store.value == "hi")
    } }

    @Test("Backspace deletes the character before the cursor")
    func backspaceDeletes() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abc"
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        let keyHandler = rig.registry.handlers(for: node).key!
        let backspace = KeyEvent(scancode: 42, keycode: 0, modifiers: [], isRepeat: false)
        let result = keyHandler(backspace, .target)
        #expect(result == .handled)
        #expect(rig.store.value == "ab")
    } }

    @Test("Left/right arrows move the cursor; insertion respects new position")
    func arrowsMoveCursor() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "hello"
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        let h = rig.registry.handlers(for: node)
        let home  = KeyEvent(scancode: 74, keycode: 0, modifiers: [], isRepeat: false)
        let right = KeyEvent(scancode: 79, keycode: 0, modifiers: [], isRepeat: false)

        // Cursor starts at end (index 5). Move home then right twice → index 2.
        _ = h.key!(home, .target)
        _ = h.key!(right, .target)
        _ = h.key!(right, .target)
        // Insert 'X' at position 2.
        _ = h.text!("X", .target)
        #expect(rig.store.value == "heXllo")

        // Backspace at the post-insert position deletes the 'X'.
        let backspace = KeyEvent(scancode: 42, keycode: 0, modifiers: [], isRepeat: false)
        _ = h.key!(backspace, .target)
        #expect(rig.store.value == "hello")
    } }

    @Test("Return triggers onSubmit")
    func returnSubmits() { GlobalTestLock.locked {
        let rig = makeRig()
        var submitted = false
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store), onSubmit: { submitted = true })
        )

        let node = fieldNode(in: rig.tree.root)
        let keyHandler = rig.registry.handlers(for: node).key!
        let ret = KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false)
        _ = keyHandler(ret, .target)
        #expect(submitted == true)
    } }

    @Test("Focus callbacks and style state update without draw")
    func focusStateUpdatesWithoutDraw() { GlobalTestLock.locked {
        let rig = makeRig()
        let probe = TextFieldInteractionProbe()
        var focusCount = 0
        var blurCount = 0

        rig.graph.install(root:
            TextField(text: makeBinding(rig.store),
                      onFocus: { focusCount += 1 },
                      onBlur: { blurCount += 1 })
                .textFieldStyle(ProbingTextFieldStyle(probe: probe))
        )

        let node = fieldNode(in: rig.tree.root)
        #expect(probe.focusedStates.last == false)
        #expect(probe.editingStates.last == false)

        rig.focus.focus(node)
        rig.graph.recomposer.commitAll()
        #expect(focusCount == 1)
        #expect(blurCount == 0)
        #expect(probe.focusedStates.last == true)
        #expect(probe.editingStates.last == true)

        rig.focus.clear()
        rig.graph.recomposer.commitAll()
        #expect(focusCount == 1)
        #expect(blurCount == 1)
        #expect(probe.focusedStates.last == false)
        #expect(probe.editingStates.last == false)
    } }

    @Test("Vertical axis inserts newline on Return instead of submitting")
    func multilineReturnInsertsNewline() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abc"
        var submitted = false
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store), axis: .vertical, onSubmit: { submitted = true })
        )

        let node = fieldNode(in: rig.tree.root)
        let keyHandler = rig.registry.handlers(for: node).key!
        let ret = KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false)
        _ = keyHandler(ret, .target)
        #expect(rig.store.value == "abc\n")
        #expect(submitted == false)
    } }

    @Test("Vertical axis uses Cmd-Return for submit")
    func multilineCmdReturnSubmits() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abc"
        var submitted = false
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store), axis: .vertical, onSubmit: { submitted = true })
        )

        let node = fieldNode(in: rig.tree.root)
        let keyHandler = rig.registry.handlers(for: node).key!
        let ret = KeyEvent(scancode: 40, keycode: 0, modifiers: [.lgui], isRepeat: false)
        _ = keyHandler(ret, .target)
        #expect(rig.store.value == "abc")
        #expect(submitted == true)
    } }

    @Test("Shift-Return inserts newline in the default field without submitting")
    func shiftReturnInsertsNewline() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abc"
        var submitted = false
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store), onSubmit: { submitted = true })
        )

        let node = fieldNode(in: rig.tree.root)
        let keyHandler = rig.registry.handlers(for: node).key!
        _ = keyHandler(key(40, shift: true), .target)

        #expect(rig.store.value == "abc\n")
        #expect(submitted == false)
    } }

    @Test("Up and down arrows preserve preferred column across explicit lines")
    func upDownArrowsPreserveColumn() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abcd\na\nabc"
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        let handlers = rig.registry.handlers(for: node)

        _ = handlers.key!(key(82), .target)
        _ = handlers.key!(key(82), .target)
        _ = handlers.text!("X", .target)
        #expect(rig.store.value == "abcXd\na\nabc")

        _ = handlers.key!(key(74), .target)
        _ = handlers.key!(key(81), .target)
        _ = handlers.text!("Y", .target)
        #expect(rig.store.value == "abcXd\nYa\nabc")
    } }

    @Test("Unhandled scancode returns .ignored so bubbling continues")
    func unhandledKeyBubbles() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        let keyHandler = rig.registry.handlers(for: node).key!
        let arbitrary = KeyEvent(scancode: 9999, keycode: 0, modifiers: [], isRepeat: false)
        #expect(keyHandler(arbitrary, .target) == .ignored)
    } }

    @Test("EventDispatcher routes textInput to the focused node")
    func dispatcherRoutesText() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        rig.focus.focus(node)

        let dispatcher = EventDispatcher(
            tree: rig.tree,
            interactions: rig.registry,
            capture: PointerCapture(),
            focusChain: rig.focus
        )
        dispatcher.dispatch(.textInput("ok"))
        #expect(rig.store.value == "ok")
    } }

    @Test("EventDispatcher routes textEditing and layout commit publishes text input area")
    func dispatcherRoutesTextEditing() { GlobalTestLock.locked {
        let rig = makeRig()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        rig.focus.focus(node)

        let dispatcher = EventDispatcher(
            tree: rig.tree,
            interactions: rig.registry,
            capture: PointerCapture(),
            focusChain: rig.focus
        )
        dispatcher.dispatch(.textEditing(TextEditingEvent(text: "ni", start: 2, length: 0)))
        #expect(rig.store.value == "")

        rig.graph.computeLayout(width: 180, height: 64)
        let area = node.attachments[TextInputAttachmentKey.area] as? TextInputArea
        #expect((area?.x ?? 0) >= 0)
        #expect((area?.y ?? -1) >= 0)
        #expect((area?.y ?? .greatestFiniteMagnitude) <= Float(node.frame.height))
        #expect((area?.width ?? 0) > 0)
        #expect(area?.cursorX == 0)

        dispatcher.dispatch(.textInput("你"))
        #expect(rig.store.value == "你")
    } }

    @Test("Backspace removes a full grapheme cluster (emoji)")
    func backspaceRemovesGrapheme() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "a😀b"  // 3 Characters
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        let key = rig.registry.handlers(for: node).key!
        let backspace = KeyEvent(scancode: 42, keycode: 0, modifiers: [], isRepeat: false)
        // Cursor at end (index 3). Backspace once → removes the emoji.
        _ = key(backspace, .target)
        #expect(rig.store.value == "a😀")
        // Backspace again → removes the emoji.
        _ = key(backspace, .target)
        #expect(rig.store.value == "a")
    } }

    @Test("Click handler is registered and tolerates an empty text-environment")
    func clickHandlerRegistered() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        let pointer = rig.registry.handlers(for: node).pointer!
        // No TextEnvironment installed; the click must not crash and must
        // leave the cursor unchanged on an empty string.
        let evt = MouseButtonEvent(button: .left, x: 100, y: 5, clicks: 1)
        let result = pointer(evt, .down, .target)
        #expect(result == .handled)
    } }

    @Test("Vertical axis reports a taller measured height for multiple lines")
    func multilineMeasuresTaller() { GlobalTestLock.locked {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let store = TextStore()
        store.value = "line 1\nline 2\nline 3"
        InteractionRegistryHolder.current = InteractionRegistry()
        FocusChainHolder.current = FocusChain()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        graph.install(root:
            TextField(text: makeBinding(store), axis: .vertical)
        )
        graph.computeLayout(width: 200, height: 200)

        let node = fieldNode(in: tree.root)
        #expect(Float(node.frame.height) > 32)
    } }

    @Test("Default TextField auto-grows for explicit multiline content and shows a scrollbar when capped")
    func multilineAutoGrowCapsAndScrolls() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = Array(repeating: "line", count: 12).joined(separator: "\n")
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )
        rig.graph.computeLayout(width: 240, height: 400)

        let node = fieldNode(in: rig.tree.root)
        #expect(Float(node.frame.height) > 32)
        #expect(Float(node.frame.height) < 12 * 20 + 12)

        let list = DrawList()
        node.draw?(list, CGPoint.zero)

        let overlay = DrawList()
        node.overlayDraw?(overlay, CGPoint.zero)
        #expect(overlay.indices.isEmpty == false)

        let wheel = rig.registry.handlers(for: node).wheel
        #expect(wheel != nil)
        _ = wheel?(MouseWheelEvent(x: 0, y: -1), .target)
        #expect(Float(node.contentOffset.y) > 0)
    } }

    @Test("Manual TextField wheel scrolling survives redraw")
    func wheelScrollPersistsAcrossRedraw() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = Array(repeating: "line", count: 12).joined(separator: "\n")
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )
        rig.graph.computeLayout(width: 240, height: 400)

        let node = fieldNode(in: rig.tree.root)
        let wheel = rig.registry.handlers(for: node).wheel!
        _ = wheel(MouseWheelEvent(x: 0, y: -1), .target)
        let scrolledOffset = node.contentOffset.y
        #expect(scrolledOffset > 0)

        let list = DrawList()
        node.draw?(list, CGPoint.zero)
        #expect(node.contentOffset.y == scrolledOffset)
    } }

    @Test("Focused TextField wheel scrolling survives redraw")
    func focusedWheelScrollPersistsAcrossRedraw() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = Array(repeating: "line", count: 12).joined(separator: "\n")
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )
        rig.graph.computeLayout(width: 240, height: 400)

        let node = fieldNode(in: rig.tree.root)
        rig.focus.focus(node)
        let wheel = rig.registry.handlers(for: node).wheel!
        _ = wheel(MouseWheelEvent(x: 0, y: -1), .target)
        let scrolledOffset = node.contentOffset.y
        #expect(scrolledOffset > 0)

        let list = DrawList()
        node.draw?(list, CGPoint.zero)
        #expect(node.contentOffset.y == scrolledOffset)
    } }

    @Test("Vertical axis soft-wraps long lines at constrained width")
    func verticalAxisSoftWrapsLongLines() { GlobalTestLock.locked {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let store = TextStore()
        store.value = "alpha beta gamma delta epsilon zeta eta"
        InteractionRegistryHolder.current = InteractionRegistry()
        FocusChainHolder.current = FocusChain()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        graph.install(root:
            TextField(text: makeBinding(store), axis: .vertical)
        )
        graph.computeLayout(width: 96, height: 240)

        let node = fieldNode(in: tree.root)
        #expect(Float(node.frame.height) > 32)
    } }

    @Test("Down arrow traverses soft-wrapped visual lines")
    func downArrowTraversesSoftWrappedLines() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "alpha beta gamma delta epsilon zeta"
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store), axis: .vertical)
        )
        rig.graph.computeLayout(width: 96, height: 240)

        let node = fieldNode(in: rig.tree.root)
        let handlers = rig.registry.handlers(for: node)
        let home = KeyEvent(scancode: 74, keycode: 0, modifiers: [], isRepeat: false)
        let down = KeyEvent(scancode: 81, keycode: 0, modifiers: [], isRepeat: false)

        _ = handlers.key!(home, .target)
        _ = handlers.key!(down, .target)
        _ = handlers.text!("X", .target)

        #expect(!rig.store.value.hasPrefix("Xalpha"))
    } }

    @Test("TextField renders CJK glyphs through font fallback")
    func rendersCJKGlyphs() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "你"
        let env = TestTextEnvironmentFactory.make()
        TextEnvironmentHolder.current = env

        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        node.frame = CGRect(x: 0, y: 0, width: 180, height: 28)

        let list = DrawList()
        node.draw?(list, CGPoint.zero)

        #expect(list.indices.count >= 6)

        // Stronger check: shape the same text through the env and confirm
        // the resolved glyph for "你" is not the .notdef tofu (glyphID 0).
        let font = node.attachments[StyleAttachmentKey.font] as? Font
            ?? Font.system(size: 14)
        let glyphs = env.shape(text: "你", font: font)
        #expect(!glyphs.isEmpty, "CJK shaping returned no glyphs")
        let cjkGlyph = glyphs.first { $0.cluster == 0 }
        #expect(cjkGlyph != nil, "no glyph mapped to first CJK character")
        #expect(cjkGlyph?.glyphID != 0,
                "CJK fell back to .notdef (tofu box) instead of resolving via CoreText cascade")
    } }

    @Test("TextField renders CJK glyphs in the demo bootstrapped environment")
    func rendersCJKGlyphsInBootstrappedDemoEnvironment() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "你"
        let env = TextEnvironment.bootstrapped(
            atlasTextureID: 1,
            primaryFontName: SystemFontDefaults.primaryFontName,
            defaultFont: Font.system(size: 18),
            defaultLineHeight: 22,
            defaultColor: .white,
            rasterScale: 2,
            atlasEdge: 1024
        )
        TextEnvironmentHolder.current = env

        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = fieldNode(in: rig.tree.root)
        node.frame = CGRect(x: 0, y: 0, width: 180, height: 28)

        let list = DrawList()
        node.draw?(list, CGPoint.zero)

        let font = node.attachments[StyleAttachmentKey.font] as? Font
            ?? Font.system(size: 14)
        let glyphs = env.shape(text: "你", font: font)
        let cjkGlyph = glyphs.first { $0.cluster == 0 }
        let info = cjkGlyph.flatMap { env.atlas.rasterizeGlyph(glyphIndex: $0.glyphID, fontID: $0.fontID) }

        #expect(list.indices.count == 6)
        #expect(cjkGlyph != nil)
        #expect(cjkGlyph?.glyphID != 0)
        #expect(info != nil)
        #expect((info?.width ?? 0) > 0)
        #expect((info?.height ?? 0) > 0)
    } }

    // MARK: - Phase 6.4d — selection + modifiers + clipboard

    private func key(_ scancode: UInt32, shift: Bool = false, cmd: Bool = false) -> KeyEvent {
        var mods = KeyModifiers()
        if shift { mods.insert(.lshift) }
        if cmd   { mods.insert(.lgui) }
        return KeyEvent(scancode: scancode, keycode: 0, modifiers: mods, isRepeat: false)
    }

    @Test("Shift+arrow extends selection; plain arrow collapses it")
    func shiftArrowSelection() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abcdef"
        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let h = rig.registry.handlers(for: node).key!
        // Cursor at end (6). Shift+Home → anchor=6, cursor=0 → selection [0,6).
        _ = h(key(74, shift: true), .target)
        // Type 'X' should replace whole selection.
        let textHandler = rig.registry.handlers(for: node).text!
        _ = textHandler("X", .target)
        #expect(rig.store.value == "X")
    } }

    @Test("Cmd+A selects all; backspace clears the field")
    func cmdASelectAll() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "hello"
        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let h = rig.registry.handlers(for: node).key!
        _ = h(key(4, cmd: true), .target)        // Cmd+A
        _ = h(key(42), .target)                  // backspace deletes selection
        #expect(rig.store.value == "")
    } }

    @Test("Cmd+C / Cmd+V round-trip via ClipboardHolder")
    func cmdCV() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "hello"
        var pasteboard: String = ""
        ClipboardHolder.write = { pasteboard = $0 }
        ClipboardHolder.read  = { pasteboard }
        defer {
            ClipboardHolder.write = nil
            ClipboardHolder.read  = nil
        }

        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let h = rig.registry.handlers(for: node).key!
        _ = h(key(4, cmd: true), .target)        // select all
        _ = h(key(6, cmd: true), .target)        // copy
        #expect(pasteboard == "hello")

        _ = h(key(77), .target)                  // End — collapse to end
        _ = h(key(25, cmd: true), .target)       // paste
        #expect(rig.store.value == "hellohello")
    } }

    @Test("Cmd+X cuts the selection to the clipboard")
    func cmdX() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abcdef"
        var pasteboard: String = ""
        ClipboardHolder.write = { pasteboard = $0 }
        ClipboardHolder.read  = { pasteboard }
        defer {
            ClipboardHolder.write = nil
            ClipboardHolder.read  = nil
        }

        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let h = rig.registry.handlers(for: node).key!
        // Cursor at end (6). Shift+Left x3 → select last 3 chars.
        _ = h(key(80, shift: true), .target)
        _ = h(key(80, shift: true), .target)
        _ = h(key(80, shift: true), .target)
        _ = h(key(27, cmd: true), .target)       // cut
        #expect(pasteboard == "def")
        #expect(rig.store.value == "abc")
    } }

    @Test("Typing with an active selection replaces the selected range")
    func typingReplacesSelection() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abcdef"
        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let h = rig.registry.handlers(for: node).key!
        let txt = rig.registry.handlers(for: node).text!
        _ = h(key(74), .target)                  // Home → cursor=0, anchor=nil
        _ = h(key(79, shift: true), .target)     // Shift+Right → select 'a'
        _ = h(key(79, shift: true), .target)     // Shift+Right → select 'ab'
        _ = txt("Z", .target)
        #expect(rig.store.value == "Zcdef")
    } }

    // MARK: - Phase 6.4e — drag selection + multi-click

    @Test("Triple click selects the entire field")
    func tripleClickSelectsAll() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "hello world"
        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let pointer = rig.registry.handlers(for: node).pointer!
        let evt = MouseButtonEvent(button: .left, x: 50, y: 5, clicks: 3)
        _ = pointer(evt, .down, .target)

        // Backspace must wipe the field — the entire range is selected.
        let key = rig.registry.handlers(for: node).key!
        _ = key(KeyEvent(scancode: 42, keycode: 0, modifiers: [], isRepeat: false), .target)
        #expect(rig.store.value == "")
    } }

    @Test("Double click selects the word at the cursor; non-word click selects the run")
    func doubleClickSelectsWord() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "hello   world"
        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let pointer = rig.registry.handlers(for: node).pointer!

        // Without a TextEnvironment installed, characterIndex returns 0 → the
        // double-click anchors on character 0, which lives in the word "hello".
        let evt = MouseButtonEvent(button: .left, x: 0, y: 5, clicks: 2)
        _ = pointer(evt, .down, .target)

        // Type 'X' — the selected word is replaced.
        let txt = rig.registry.handlers(for: node).text!
        _ = txt("X", .target)
        #expect(rig.store.value == "X   world")
    } }

    @Test("Pointer-down acquires capture; pointer-up releases it")
    func dragAcquiresAndReleasesCapture() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abc"
        let capture = PointerCapture()
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = nil }

        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let pointer = rig.registry.handlers(for: node).pointer!

        let down = MouseButtonEvent(button: .left, x: 5, y: 5, clicks: 1)
        _ = pointer(down, .down, .target)
        #expect(capture.target === node)

        let up = MouseButtonEvent(button: .left, x: 5, y: 5, clicks: 1)
        _ = pointer(up, .up, .target)
        #expect(capture.target == nil)
    } }

    @Test("Motion events are ignored unless a drag is in progress")
    func motionIgnoredWithoutDrag() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = "abc"
        rig.graph.install(root: TextField(text: makeBinding(rig.store)))
        let node = fieldNode(in: rig.tree.root)
        let motion = rig.registry.handlers(for: node).motion!

        let evt = MouseMotionEvent(x: 100, y: 5, deltaX: 1, deltaY: 0)
        #expect(motion(evt, .target) == .ignored)
    } }
}
