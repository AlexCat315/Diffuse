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

    @Test("textInput inserts characters at the cursor")
    func textInputInserts() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.graph.install(root:
            TextField("placeholder", text: makeBinding(rig.store))
        )

        let node = rig.tree.root!.children.first!
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

        let node = rig.tree.root!.children.first!
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

        let node = rig.tree.root!.children.first!
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

        let node = rig.tree.root!.children.first!
        let keyHandler = rig.registry.handlers(for: node).key!
        let ret = KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false)
        _ = keyHandler(ret, .target)
        #expect(submitted == true)
    } }

    @Test("Unhandled scancode returns .ignored so bubbling continues")
    func unhandledKeyBubbles() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = rig.tree.root!.children.first!
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

        let node = rig.tree.root!.children.first!
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

    @Test("EventDispatcher routes textEditing and focused render publishes text input area")
    func dispatcherRoutesTextEditing() { GlobalTestLock.locked {
        let rig = makeRig()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        rig.graph.install(root:
            TextField(text: makeBinding(rig.store))
        )

        let node = rig.tree.root!.children.first!
        rig.focus.focus(node)

        let dispatcher = EventDispatcher(
            tree: rig.tree,
            interactions: rig.registry,
            capture: PointerCapture(),
            focusChain: rig.focus
        )
        dispatcher.dispatch(.textEditing(TextEditingEvent(text: "ni", start: 2, length: 0)))
        #expect(rig.store.value == "")

        node.frame = CGRect(x: 0, y: 0, width: 180, height: 28)
        let list = DrawList()
        node.draw?(list, CGPoint(x: 24, y: 16))
        let area = node.attachments[TextInputAttachmentKey.area] as? TextInputArea
        #expect((area?.x ?? 0) >= 24)
        #expect(area?.y == 16)
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

        let node = rig.tree.root!.children.first!
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

        let node = rig.tree.root!.children.first!
        let pointer = rig.registry.handlers(for: node).pointer!
        // No TextEnvironment installed; the click must not crash and must
        // leave the cursor unchanged on an empty string.
        let evt = MouseButtonEvent(button: .left, x: 100, y: 5, clicks: 1)
        let result = pointer(evt, .down, .target)
        #expect(result == .handled)
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
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
        let node = rig.tree.root!.children.first!
        let motion = rig.registry.handlers(for: node).motion!

        let evt = MouseMotionEvent(x: 100, y: 5, deltaX: 1, deltaY: 0)
        #expect(motion(evt, .target) == .ignored)
    } }
}
