import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Sectioned list", .serialized)
struct SectionedListTests: GuavaUIComposeSerializedSuite {
    private struct Item: Identifiable, Equatable {
        let id: Int
        var title: String { "Item \(id)" }
    }

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

    private func click(_ node: Node, registry: InteractionRegistry,
                       focus: FocusChain, capture: PointerCapture) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        let pointer = registry.handlers(for: node).pointer!
        _ = pointer(event, .down, .target)
        _ = pointer(event, .up, .target)
    }

    @Test("Sections render headers/footers and keyboard navigation")
    func sectionsAndKeyboard() {
        withScene { graph, registry, focus, capture in
            var selected: Int? = 1
            var activated: Int?
            let sections = [
                ListSection("a", title: "Alpha", footer: "End of Alpha",
                            items: [Item(id: 1), Item(id: 2)])
            ]
            graph.install(root: SectionedList(sections, selection: Binding(get: { selected }, set: { selected = $0 }),
                                              onActivate: { activated = $0.id }) { item, _ in
                Text(item.title)
            }.frame(width: 240, height: 600))
            graph.computeLayout(width: 280, height: 700)
            let all = nodes(graph.tree.root)
            let hasAlpha = all.contains { $0.accessibility?.label == "Alpha" }
            let hasFooter = all.contains { $0.accessibility?.label == "End of Alpha" }
            #expect(hasAlpha && hasFooter)
            let rows = all.filter { $0.accessibility?.role == .listItem }
            #expect(rows.count == 2)
            guard rows.count == 2 else { return }

            click(rows[0], registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selected == 1)

            let host = all.first { $0.isFocusable && registry.handlers(for: $0).key != nil }!
            focus.focus(host)
            let key = registry.handlers(for: host).key!
            _ = key(KeyEvent(scancode: Scancode.arrowDown, keycode: 0, modifiers: [], isRepeat: false), .target)
            graph.recomposer.commitAll()
            #expect(selected == 2)
            _ = key(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false), .target)
            #expect(activated == 2)
        }
    }
}
