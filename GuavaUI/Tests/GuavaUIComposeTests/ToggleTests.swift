import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 8 Toggle", .serialized)
struct ToggleTests: GuavaUIComposeSerializedSuite {

    private func key(_ scancode: UInt32) -> KeyEvent {
        KeyEvent(scancode: scancode, keycode: 0, modifiers: [], isRepeat: false)
    }

    private func host(in tree: NodeTree) -> Node {
        tree.root!.children.first!.children.first!.children.first!
    }

    private func makeBinding(_ initial: Bool) -> (Binding<Bool>, () -> Bool) {
        var storage = initial
        let binding = Binding<Bool>(
            get: { storage },
            set: { storage = $0 }
        )
        return (binding, { storage })
    }

    @Test("Toggle materialises a hit-testable, focusable host node")
    func materialise() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, _) = makeBinding(false)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Toggle(isOn: binding))

        let h = host(in: tree)
        #expect(h.isHitTestable == true)
        #expect(h.isFocusable == true)
        #expect(registry.handlers(for: h).pointer != nil)
        #expect(registry.handlers(for: h).hover != nil)
    } }

    @Test("Pointer down then up toggles the binding")
    func pointerUpTogglesBinding() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(false)
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: Toggle(isOn: binding))
        graph.computeLayout(width: 100, height: 24)

        let h = host(in: tree)
        let pointer = registry.handlers(for: h).pointer!
        let evt = MouseButtonEvent(button: .left, x: 12, y: 12, clicks: 1)

        _ = pointer(evt, .down, .target)
        recomp.commitAll()
        #expect(read() == false)

        _ = pointer(evt, .up, .target)
        recomp.commitAll()
        #expect(read() == true)

        _ = pointer(evt, .down, .target)
        recomp.commitAll()
        _ = pointer(evt, .up, .target)
        recomp.commitAll()
        #expect(read() == false)
    } }

    @Test("Right click is ignored")
    func rightClickIgnored() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(false)
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: Toggle(isOn: binding))
        graph.computeLayout(width: 100, height: 24)

        let h = host(in: tree)
        let pointer = registry.handlers(for: h).pointer!
        let evt = MouseButtonEvent(button: .right, x: 12, y: 12, clicks: 1)

        #expect(pointer(evt, .down, .target) == .ignored)
        recomp.commitAll()
        #expect(pointer(evt, .up, .target) == .ignored)
        #expect(read() == false)
    } }

    @Test("Disabled toggle does not register pointer handlers")
    func disabledIgnoresInput() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(true)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Toggle(isOn: binding, isEnabled: false))
        graph.computeLayout(width: 100, height: 24)

        let h = host(in: tree)
        #expect(registry.handlers(for: h).pointer == nil)
        #expect(h.cursor == .notAllowed)
        #expect(read() == true)
    } }

    @Test("Keyboard Space toggles the focused control")
    func spaceKeyTogglesBinding() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(false)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Toggle(isOn: binding))

        let h = host(in: tree)
        let keyHandler = registry.handlers(for: h).key!
        #expect(keyHandler(key(44), .target) == .handled)
        #expect(read() == true)
    } }

    @Test("Keyboard Return toggles the focused control")
    func returnKeyTogglesBinding() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(false)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Toggle(isOn: binding))

        let h = host(in: tree)
        let keyHandler = registry.handlers(for: h).key!
        #expect(keyHandler(key(40), .target) == .handled)
        #expect(read() == true)
    } }

    @Test("Checkbox shares the same bool activation semantics")
    func checkboxSharesBoolSemantics() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(false)
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: Checkbox(isOn: binding))
        graph.computeLayout(width: 40, height: 24)

        let h = host(in: tree)
        let pointer = registry.handlers(for: h).pointer!
        let evt = MouseButtonEvent(button: .left, x: 8, y: 8, clicks: 1)
        _ = pointer(evt, .down, .target)
        recomp.commitAll()
        _ = pointer(evt, .up, .target)
        recomp.commitAll()
        #expect(read() == true)

        let keyHandler = registry.handlers(for: h).key!
        #expect(keyHandler(key(44), .target) == .handled)
        #expect(read() == false)
    } }
}