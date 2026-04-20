import Testing
@testable import GuavaUIRuntime

@Suite("FocusChain")
struct FocusChainTests {

    private func makeTree() -> (root: Node, focusables: [Node]) {
        // root
        // ├── A (focusable)
        // ├── container
        // │   ├── B (focusable)
        // │   └── C (not focusable)
        // └── D (focusable)
        let root = Node()
        let a = Node(); a.isFocusable = true
        let container = Node()
        let b = Node(); b.isFocusable = true
        let c = Node()
        let d = Node(); d.isFocusable = true

        root.addChild(a)
        root.addChild(container)
        container.addChild(b)
        container.addChild(c)
        root.addChild(d)
        return (root, [a, b, d])
    }

    @Test("focusNext from nothing focuses first focusable in tree order")
    func nextFromNil() {
        let (root, focusables) = makeTree()
        let fc = FocusChain()
        let next = fc.focusNext(in: root)
        #expect(next === focusables[0])
        #expect(fc.focused === focusables[0])
    }

    @Test("focusNext walks tree-order and wraps")
    func nextWraps() {
        let (root, focusables) = makeTree()
        let fc = FocusChain()
        fc.focus(focusables[0])
        #expect(fc.focusNext(in: root) === focusables[1])
        #expect(fc.focusNext(in: root) === focusables[2])
        #expect(fc.focusNext(in: root) === focusables[0])
    }

    @Test("focusPrevious wraps backwards")
    func previousWraps() {
        let (root, focusables) = makeTree()
        let fc = FocusChain()
        fc.focus(focusables[0])
        #expect(fc.focusPrevious(in: root) === focusables[2])
        #expect(fc.focusPrevious(in: root) === focusables[1])
        #expect(fc.focusPrevious(in: root) === focusables[0])
    }

    @Test("Empty focusable set returns nil")
    func empty() {
        let root = Node()
        root.addChild(Node())
        let fc = FocusChain()
        #expect(fc.focusNext(in: root) == nil)
        #expect(fc.focused == nil)
    }
}

@Suite("PointerCapture")
struct PointerCaptureTests {

    @Test("acquire then release")
    func basic() {
        let cap = PointerCapture()
        let n = Node()
        #expect(!cap.isActive)
        cap.acquire(n)
        #expect(cap.isActive)
        #expect(cap.target === n)
        cap.release()
        #expect(!cap.isActive)
    }
}

@Suite("InteractionRegistry")
struct InteractionRegistryTests {

    @Test("Empty by default; handlers query returns empty struct")
    func defaultEmpty() {
        let reg = InteractionRegistry()
        let n = Node()
        #expect(reg.handlers(for: n).isEmpty)
        #expect(reg.count == 0)
    }

    @Test("Set and remove pointer handler")
    func setAndRemove() {
        let reg = InteractionRegistry()
        let n = Node()
        reg.setPointer(n) { _, _, _ in .handled }
        #expect(reg.handlers(for: n).pointer != nil)
        reg.remove(n)
        #expect(reg.handlers(for: n).isEmpty)
    }
}
