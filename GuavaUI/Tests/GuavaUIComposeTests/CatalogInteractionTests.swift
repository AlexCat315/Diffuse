import Foundation
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Component interaction contracts", .serialized)
struct CatalogInteractionTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func key(_ code: UInt32) -> KeyEvent { KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false) }
    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current, oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry; FocusChainHolder.current = focus; PointerCaptureHolder.current = capture
            defer { InteractionRegistryHolder.current = oldRegistry; FocusChainHolder.current = oldFocus; PointerCaptureHolder.current = oldCapture }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, focus, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    @Test("Disabled controls leave the focus chain and release an active drag")
    func disabledInteractionCleanup() {
        withScene { graph, registry, focus, capture in
            graph.install(root: Toggle(isOn: .constant(false)))
            graph.computeLayout(width: 120, height: 40)
            let host = nodes(graph.tree.root!).first { $0.attachments[BoolControlHost.variantKey] != nil }!
            focus.focus(host)
            capture.acquire(host)
            BoolControlHost(isOn: .constant(false), isEnabled: false, variant: .toggle)._updateNode(host)
            #expect(!host.isFocusable)
            #expect(focus.focused == nil && capture.target == nil)
            #expect(registry.handlers(for: host).key == nil)
            graph.install(root: Slider(value: .constant(0.5), isEnabled: false))
            #expect(nodes(graph.tree.root!).allSatisfy { !$0.isFocusable })
        }
    }

    @Test("Toggle captures the pointer and cancels an outside release")
    func toggleOutsideRelease() {
        withScene { graph, registry, _, capture in
            var value = false
            graph.install(root: Toggle(isOn: Binding(get: { value }, set: { value = $0 })))
            graph.computeLayout(width: 100, height: 40)
            let host = nodes(graph.tree.root!).first { $0.attachments[BoolControlHost.variantKey] != nil }!
            let pointer = registry.handlers(for: host).pointer!
            _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
            #expect(capture.target === host)
            _ = pointer(MouseButtonEvent(button: .left, x: 1000, y: 1000, clicks: 1), .up, .target)
            #expect(!value && capture.target == nil)
            #expect(host.attachments[BoolControlHost.pressedKey] as? Bool == false)
        }
    }

    @Test("Mixed checkbox activation resolves to checked")
    func mixedCheckboxActivation() {
        withScene { graph, registry, _, _ in
            var value: CheckboxState = .mixed
            graph.install(root: Checkbox(state: Binding(get: { value }, set: { value = $0 })))
            let host = nodes(graph.tree.root!).first { $0.attachments[BoolControlHost.variantKey] != nil }!
            #expect(host.attachments[BoolControlHost.onKey] as? Bool == true)
            #expect(registry.handlers(for: host).key?(key(Scancode.space), .target) == .handled)
            #expect(value == .on)
        }
    }

    @Test("Slider keyboard stepping honors offset ranges and ignores secondary clicks")
    func sliderKeyboardAndPointer() {
        withScene { graph, registry, _, _ in
            var value = 11.0
            graph.install(root: Slider(value: Binding(get: { value }, set: { value = $0 }), range: 10...20, step: 2))
            graph.computeLayout(width: 200, height: 24)
            let host = nodes(graph.tree.root!).first { $0.attachments[SliderHost.pressedKey] != nil }!
            let handler = registry.handlers(for: host).key!
            #expect(handler(key(Scancode.arrowRight), .target) == .handled)
            #expect(value == 14)
            _ = handler(key(Scancode.home), .target); #expect(value == 10)
            _ = handler(key(Scancode.end), .target); #expect(value == 20)
            let pointer = registry.handlers(for: host).pointer!
            #expect(pointer(MouseButtonEvent(button: .right, x: 0, y: 0, clicks: 1), .down, .target) == .ignored)
            #expect(value == 20)
        }
    }

    @Test("Tab arrows skip disabled tabs, wrap and move actual focus")
    func tabsMoveFocus() {
        withScene { graph, registry, focus, capture in
            var selected = "a"
            graph.install(root: TabView(selection: Binding(get: { selected }, set: { selected = $0 }), tabs: [
                TabItem("A", id: "a") { Text("A") }, TabItem("B", id: "b", isEnabled: false) { Text("B") }, TabItem("C", id: "c") { Text("C") }
            ]))
            let buttons = nodes(graph.tree.root!).filter { $0.attachments[ButtonHost.markerKey] as? Bool == true }
            #expect(buttons.count == 3)
            focus.focusNext(in: graph.tree.root!)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selected == "c")
            #expect(focus.focused === buttons[2])
            #expect(buttons[2].isTabStop && !buttons[0].isTabStop)
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selected == "a")
        }
    }

    @Test("List selection navigates from no selection and activates only on Return")
    func listKeyboard() {
        withScene { graph, registry, _, _ in
            var selected: Int? = nil, activated: Int? = nil
            graph.install(root: List([10, 20, 30], id: \.self, selection: Binding(get: { selected }, set: { selected = $0 }), onActivate: { activated = $0 }) { item, _ in Text("\(item)") })
            graph.computeLayout(width: 200, height: 100)
            let host = nodes(graph.tree.root!).first { $0.isFocusable && registry.handlers(for: $0).key != nil }!
            let handler = registry.handlers(for: host).key!
            _ = handler(key(Scancode.arrowDown), .target); #expect(selected == 10 && activated == nil)
            _ = handler(key(Scancode.end), .target); #expect(selected == 30)
            _ = handler(key(Scancode.return), .target); #expect(activated == 30)
        }
    }

    @Test("Loading blocks activation and cancels the spinner on unmount")
    func loadingLifecycle() {
        withScene { graph, registry, _, _ in
            var calls = 0
            graph.install(root: Button("Save", isLoading: true) { calls += 1 })
            let host = nodes(graph.tree.root!).first { $0.attachments[ButtonHost.markerKey] as? Bool == true }!
            #expect(!host.isFocusable && registry.handlers(for: host).pointer == nil)
            #expect(AnimatorScheduler.current.activeCount > 0)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
            #expect(AnimatorScheduler.current.activeCount == 0 && calls == 0)
        }
    }

    @Test("TextField groups validate independently and copy without carrying editing state")
    func groupedTextField() {
        withScene { graph, registry, _, _ in
            var text: TextBuffer = "abc"
            let field = TextField("Name", text: Binding(get: { text }, set: { text = $0 })) {
                $0.layout.maxVisibleLines = 0
                $0.codeEditing.indentationWidth = 99
                $0.behavior.maxLength = -2
            }
            #expect(field.layout.maxVisibleLines == 1)
            #expect(field.codeEditing.indentationWidth == 8)
            #expect(field.behavior.maxLength == 0)
            graph.install(root: field)
            let host = nodes(graph.tree.root!).first { $0.attachments["__textfield_state"] != nil }!
            #expect(registry.handlers(for: host).text?("z", .target) == .handled)
            #expect(text.stringValue == "abc")
            var copy = field
            copy.decoration.prefix = "@"
            #expect(field.decoration.prefix == nil)
        }
    }
}
