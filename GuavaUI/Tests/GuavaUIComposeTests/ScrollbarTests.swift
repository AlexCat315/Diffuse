import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Focusable scrollbar", .serialized)
struct ScrollbarTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var offset: CGFloat = 0
        var body: some View {
            Scrollbar(offset: $offset, contentExtent: 800, viewportExtent: 240)
                .frame(width: 12, height: 240)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<5 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 200, height: 300)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    private func scene(_ body: (ViewGraph, PlatformInputContext, EventDispatcher, Harness) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            try context.withCurrent {
                let harness = Harness()
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                 capture: context.pointerCapture,
                                                 focusChain: context.focusChain)
                graph.install(root: harness)
                settle(graph)
                defer { graph.install(root: EmptyView()) }
                try body(graph, context, dispatcher, harness)
            }
        }
    }

    private func thumb(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root!).first {
            $0.accessibility?.role == .slider && $0.accessibility?.label == "Scrollbar"
        })
    }

    @Test("Keyboard, accessibility and setValue move a focused thumb")
    func keyboard() throws {
        try scene { graph, context, dispatcher, harness in
            let bar = try thumb(graph)
            #expect(bar.accessibility?.value == "0%")
            #expect(bar.isFocusable)
            context.focusChain.focus(bar)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.pageDown, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(harness.offset > 0)
            #expect(bar.accessibility?.value != "0%")

            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.home, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(harness.offset == 0)
            bar.accessibilityActions.increment?()
            settle(graph)
            #expect(harness.offset > 0)
            bar.accessibilityActions.setValue?("50%")
            settle(graph)
            #expect(abs(harness.offset - 280) < 1)
        }
    }

    @Test("Dragging the thumb maps pointer travel to the offset")
    func drag() throws {
        try scene { graph, _, dispatcher, harness in
            let bar = try thumb(graph)
            let frame = bar.absoluteFrame
            let start = CGPoint(x: frame.midX, y: frame.minY + 12)
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: Float(start.x), y: Float(start.y), clicks: 1)))
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
                x: Float(start.x), y: Float(frame.maxY - 8), deltaX: 0, deltaY: Float(frame.height - 20))))
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
                button: .left, x: Float(start.x), y: Float(frame.maxY - 8), clicks: 1)))
            settle(graph)
            #expect(harness.offset > 500)
        }
    }

    @Test("The scrollbar uses the requested thickness and viewport height")
    func geometry() throws {
        try scene { graph, _, _, _ in
            let bar = try thumb(graph)
            #expect(bar.frame.height == 240)
            #expect(bar.frame.width == 12)
            #expect(bar.accessibility?.value == "0%")
        }
    }
}
