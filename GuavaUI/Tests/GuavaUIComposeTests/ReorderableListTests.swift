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
        var items: [Item]
        var moves: [(Int, Int)] = []
        init(count: Int = 4) { items = (0..<count).map(Item.init(id:)) }
    }

    private struct Harness: View {
        @State var items: [Item]
        let model: Model
        var height: Float = 500
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
            .frame(width: 280, height: height)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func withScene(_ input: UIEnvironment.Input = [.pointer, .keyboard], count: Int = 4, height: Float = 500,
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
                let model = Model(count: count)
                let harness = Harness(items: model.items, model: model, height: height)
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
    @Test("Holding a dragged row at the bottom edge scrolls the list and drops below the fold")
    func edgeAutoScroll() throws {
        try withScene(count: 30, height: 200) { graph, _, dispatcher, harness in
            let source = try handle(0, graph)
            let start = source.absoluteFrame
            let scroll = try #require(EnclosingScroll.container(of: source))
            let viewport = EnclosingScroll.viewport(of: scroll)
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: Float(start.midX),
                                                                  y: Float(start.midY), clicks: 1)))
            settle(graph)
            // Mid-viewport: no automatic scroll.
            let middle = Float(viewport.midY)
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(start.midX), y: middle, deltaX: 0, deltaY: 0)))
            for _ in 0..<5 { AnimatorScheduler.current.tick(deltaTime: 0.1); settle(graph) }
            #expect(scroll.contentOffset.y == 0)
            // Resting at the bottom edge keeps scrolling without pointer motion.
            let edge = Float(viewport.maxY) - 2
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(start.midX), y: edge, deltaX: 0, deltaY: 0)))
            for _ in 0..<5 { AnimatorScheduler.current.tick(deltaTime: 0.1); settle(graph) }
            let scrolled = scroll.contentOffset.y
            #expect(scrolled > 200, "scrolled \(scrolled)")
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: Float(start.midX), y: edge, clicks: 1)))
            settle(graph)
            let destination = try #require(harness.model.moves.first?.1)
            // The drop lands where the pointer is in content coordinates.
            let expected = Int(((CGFloat(edge) - start.midY + scrolled) / 36).rounded()) - 1
            #expect(abs(destination - expected) <= 1, "dropped at \(destination), expected about \(expected)")
            #expect(destination > 6, "below the initially visible rows")
            AnimatorScheduler.current.tick(deltaTime: 0.1)
            #expect(scroll.contentOffset.y == scrolled, "released drags stop scrolling")
        }
    }

    @Test("Edge speed is zero mid-viewport and rises to the maximum at and beyond the edge")
    func edgeVelocity() {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 400)
        #expect(EdgeAutoScroll.velocity(pointerY: 300, viewport: viewport) == 0)
        #expect(EdgeAutoScroll.velocity(pointerY: 100, viewport: viewport) == -EdgeAutoScroll.maximumSpeed)
        #expect(EdgeAutoScroll.velocity(pointerY: 520, viewport: viewport) == EdgeAutoScroll.maximumSpeed)
        let shallow = EdgeAutoScroll.velocity(pointerY: 470, viewport: viewport)
        let deep = EdgeAutoScroll.velocity(pointerY: 490, viewport: viewport)
        #expect(shallow > 0 && deep > shallow)
    }
}
