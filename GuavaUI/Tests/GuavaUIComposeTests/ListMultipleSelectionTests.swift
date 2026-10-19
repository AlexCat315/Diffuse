import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Multi-select list", .serialized)
struct ListMultipleSelectionTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let oldText = TextEnvironmentHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry
            FocusChainHolder.current = focus
            PointerCaptureHolder.current = capture
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer {
                InteractionRegistryHolder.current = oldRegistry
                FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture
                TextEnvironmentHolder.current = oldText
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, focus, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func rows(_ graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root).filter { $0.accessibility?.role == .listItem }
    }

    private func click(_ node: Node, modifiers: KeyModifiers, registry: InteractionRegistry,
                       focus: FocusChain, capture: PointerCapture) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY),
                                     clicks: 1, modifiers: modifiers)
        let pointer = registry.handlers(for: node).pointer!
        _ = pointer(event, .down, .target)
        _ = pointer(event, .up, .target)
    }

    @Test("Click, Shift-click and Cmd-click form a stable ID set")
    func pointerSelection() {
        withScene { graph, registry, focus, capture in
            var selection: Set<Int> = []
            graph.install(root: List([10, 20, 30, 40], id: \.self,
                                                selection: Binding(get: { selection }, set: { selection = $0 })) { item, _ in
                Text("\(item)")
            }.frame(width: 200, height: 500))
            graph.computeLayout(width: 240, height: 600)
            let rowNodes = rows(graph)
            #expect(rowNodes.count == 4)
            guard rowNodes.count == 4 else { return }

            click(rowNodes[1], modifiers: [], registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selection == [20])

            click(rowNodes[3], modifiers: [.shift], registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selection == [20, 30, 40])

            click(rowNodes[2], modifiers: [.gui], registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selection == [20, 40])

            click(rowNodes[2], modifiers: [.gui], registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selection == [20, 30, 40])
        }
    }

    @Test("Keyboard extends from the anchor and Cmd+A selects every row")
    func keyboardSelection() {
        withScene { graph, registry, focus, capture in
            var selection: Set<Int> = []
            graph.install(root: List([10, 20, 30, 40], id: \.self,
                                                selection: Binding(get: { selection }, set: { selection = $0 })) { item, _ in
                Text("\(item)")
            }.frame(width: 200, height: 500))
            graph.computeLayout(width: 240, height: 600)
            let rowNodes = rows(graph)
            guard rowNodes.count == 4 else {
                Issue.record("rows were not mounted")
                return
            }
            click(rowNodes[1], modifiers: [], registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            let host = nodes(graph.tree.root).first { $0.isFocusable && registry.handlers(for: $0).key != nil }!
            focus.focus(host)
            let key = registry.handlers(for: host).key!
            _ = key(KeyEvent(scancode: Scancode.arrowDown, keycode: 0, modifiers: [.shift], isRepeat: false), .target)
            graph.recomposer.commitAll()
            #expect(selection == [20, 30])
            _ = key(KeyEvent(scancode: Scancode.arrowDown, keycode: 0, modifiers: [], isRepeat: false), .target)
            graph.recomposer.commitAll()
            #expect(selection == [40])
            _ = key(KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.gui], isRepeat: false), .target)
            graph.recomposer.commitAll()
            #expect(selection == [10, 20, 30, 40])
        }
    }
}
