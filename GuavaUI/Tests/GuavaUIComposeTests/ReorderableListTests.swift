import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Reorderable list", .serialized)
struct ReorderableListTests: GuavaUIComposeSerializedSuite {
    private struct Item: Identifiable, Equatable {
        let id: Int
        var title: String { "Item \(id + 1)" }
    }

    private final class Model {
        var items: [Item] = (0..<4).map(Item.init(id:))
        var moves: [(Int, Int)] = []
    }

    private struct Harness: View {
        @State var items: [Item]
        let model: Model
        var body: some View {
            ReorderableList(items, id: \.id, rowHeight: 36,
                            rowLabel: { $0.title },
                            onMove: { from, to in
                guard items.indices.contains(from), (0..<items.count).contains(to) else { return }
                model.moves.append((from, to))
                let moved = items.remove(at: from)
                items.insert(moved, at: to)
                model.items = items
            }) { item, dragging in
                Text(item.title)
                    .foregroundColor(dragging ? .accent : .onSurface)
                    .debugName("reorder-row-\(item.id)")
            }
            .frame(width: 280, height: 500)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func withScene(_ input: UIEnvironment.Input = [.pointer, .keyboard],
                           _ body: (ViewGraph, PlatformInputContext, EventDispatcher, Harness) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let previousText = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previousText }
            try context.withCurrent {
                var environment = UIEnvironment()
                environment.viewport.width = 320
                environment.input = input
                let model = Model()
                let harness = Harness(items: model.items, model: model)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                 capture: context.pointerCapture,
                                                 focusChain: context.focusChain)
                graph.install(root: harness.surfaceEnvironment(environment))
                for _ in 0..<12 {
                    graph.recomposer.commitAll()
                    graph.computeLayout(width: 320, height: 520)
                }
                defer { graph.install(root: EmptyView()) }
                try body(graph, context, dispatcher, harness)
            }
        }
    }

    private func handle(_ index: Int, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root!).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "reorder-handle-\(index)"
        })
    }

    private func indicator(_ graph: ViewGraph) -> Node? {
        nodes(graph.tree.root!).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "reorder-drop-indicator"
        }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<8 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 320, height: 520)
        }
    }

    @Test("Dragging the handle shows a drop line and moves the row once")
    func pointerReorder() throws {
        try withScene { graph, context, dispatcher, harness in
            let source = try handle(0, graph)
            let start = source.absoluteFrame
            let down = MouseButtonEvent(button: .left, x: Float(start.midX),
                                       y: Float(start.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(down))
            settle(graph)
            #expect(context.pointerCapture.target === source)
            let sameHandle = try handle(0, graph)
            #expect(sameHandle === source)

            let moved = MouseButtonEvent(button: .left, x: Float(start.midX),
                                         y: Float(start.midY) + 80, clicks: 1)
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: moved.x, y: moved.y,
                                                              deltaX: 0, deltaY: 80)))
            settle(graph)
            #expect(indicator(graph) != nil)

            dispatcher.dispatch(.mouseButtonUp(moved))
            settle(graph)
            #expect(indicator(graph) == nil)
            #expect(harness.$items.wrappedValue.map(\.id) == [1, 0, 2, 3])
            #expect(harness.model.moves.count == 1)
            #expect(harness.model.moves.first! == (0, 1))
            #expect(context.pointerCapture.target == nil)
        }
    }

    @Test("Keyboard and assistive actions move the focused row and keep the handle")
    func keyboardReorder() throws {
        try withScene { graph, context, dispatcher, harness in
            let first = try handle(0, graph)
            context.focusChain.focus(first)
            #expect(first.accessibility?.role == .slider)
            #expect(first.accessibility?.value == "Position 1 of 4")
            #expect(first.accessibilityActions.increment != nil)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowDown, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(harness.$items.wrappedValue.map(\.id) == [1, 0, 2, 3])
            #expect(context.focusChain.focused === first)
            #expect(first.accessibility?.value == "Position 2 of 4")

            first.accessibilityActions.increment?()
            settle(graph)
            #expect(harness.$items.wrappedValue.map(\.id) == [1, 2, 0, 3])
            first.accessibilityActions.decrement?()
            settle(graph)
            #expect(harness.$items.wrappedValue.map(\.id) == [1, 0, 2, 3])
        }
    }

    @Test("Escape cancels a drag without reporting a move")
    func escapeCancels() throws {
        try withScene { graph, context, dispatcher, harness in
            let source = try handle(1, graph)
            let start = source.absoluteFrame
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: Float(start.midX), y: Float(start.midY), clicks: 1)))
            settle(graph)
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
                x: Float(start.midX), y: Float(start.midY) + 80, deltaX: 0, deltaY: 80)))
            settle(graph)
            #expect(indicator(graph) != nil)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.escape, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(indicator(graph) == nil)
            #expect(harness.$items.wrappedValue.map(\.id) == [0, 1, 2, 3])
            #expect(harness.model.moves.isEmpty)
            #expect(context.pointerCapture.target == nil)
        }
    }

    @Test("Touch surfaces reserve a 44pt handle")
    func touchHandle() throws {
        try withScene([.touch, .keyboard]) { graph, _, _, _ in
            let handle = try handle(0, graph)
            #expect(handle.frame.width >= 44)
            #expect(handle.frame.height >= 44)
            #expect(nodes(handle).contains { $0.frame.width > 0 })
        }
    }
}
