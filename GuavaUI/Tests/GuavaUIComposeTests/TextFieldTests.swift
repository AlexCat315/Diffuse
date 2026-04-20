import Testing
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
}
