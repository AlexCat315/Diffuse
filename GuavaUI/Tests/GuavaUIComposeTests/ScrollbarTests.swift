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

    @Test("Plain pointer motion over the bar does not scrub the offset")
    func hoverMotionDoesNotScrub() throws {
        try scene { graph, _, dispatcher, harness in
            let bar = try thumb(graph)
            let frame = bar.absoluteFrame
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
                x: Float(frame.midX), y: Float(frame.maxY - 8), deltaX: 0, deltaY: 0)))
            settle(graph)
            #expect(harness.offset == 0)
        }
    }

    // MARK: Auto-hide chrome

    private struct TouchHarness: View {
        @State var offset: CGFloat = 0
        var body: some View {
            var surface = UIEnvironment(); surface.input = UIEnvironment.Input([.touch])
            return Scrollbar(offset: $offset, contentExtent: 800, viewportExtent: 240)
                .frame(width: 12, height: 240)
                .surfaceEnvironment(surface)
        }
    }

    private struct ReducedHarness: View {
        @State var offset: CGFloat = 0
        var body: some View {
            Scrollbar(offset: $offset, contentExtent: 800, viewportExtent: 240)
                .frame(width: 12, height: 240)
                .reducedMotion()
        }
    }

    private func chromeScene<V: View>(root: V,
                                      _ body: (ViewGraph, Node, PlatformInputContext, AnimatorScheduler) throws -> Void) throws {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let scheduler = AnimatorScheduler()
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(scheduler) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    graph.install(root: root)
                    for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 200, height: 300) }
                    let bar = try #require(nodes(graph.tree.root!).first {
                        $0.accessibility?.role == .slider && $0.accessibility?.label == "Scrollbar"
                    })
                    defer { graph.install(root: EmptyView()) }
                    try body(graph, bar, context, scheduler)
                }
            }
        }
    }

    private func chromeOpacity(_ bar: Node) -> Float {
        bar.attachments["__scrollbar_chrome_opacity"] as? Float ?? -1
    }

    private func drawn(_ bar: Node) -> Bool {
        let list = DrawList()
        bar.draw?(list, .zero)
        return !list.vertices.isEmpty
    }

    @Test("Hover-capable surfaces hide the companion at rest, reveal on hover and fade on leave")
    func autoHideFollowsHover() throws {
        try chromeScene(root: Harness()) { _, bar, context, scheduler in
            #expect(chromeOpacity(bar) == 0)
            #expect(!drawn(bar))
            let hover = try #require(context.interactions.handlers(for: bar).hover)
            hover(.enter)
            #expect(scheduler.activeCount == 1)
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 1)
            #expect(drawn(bar))
            hover(.leave)
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 0)
            #expect(!drawn(bar))
        }
    }

    @Test("A scroll offset change flashes the companion until the content rests")
    func scrollFlash() throws {
        try chromeScene(root: Harness()) { graph, bar, _, scheduler in
            #expect(chromeOpacity(bar) == 0)
            bar.accessibilityActions.increment?()
            graph.recomposer.commitAll()
            graph.computeLayout(width: 200, height: 300)
            #expect(bar.accessibility?.value != "0%")
            #expect(chromeOpacity(bar) == 1)
            #expect(drawn(bar))
            #expect(scheduler.activeCount == 1)
            scheduler.tick(deltaTime: 0.5)
            #expect(chromeOpacity(bar) == 1)
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 0)
            #expect(!drawn(bar))
        }
    }

    @Test("Focus holds the companion visible through hover churn until blur")
    func focusHoldsVisible() throws {
        try chromeScene(root: Harness()) { graph, bar, context, scheduler in
            context.focusChain.focus(bar)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 200, height: 300)
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 1)
            let hover = try #require(context.interactions.handlers(for: bar).hover)
            hover(.enter)
            hover(.leave)
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 1)
            context.focusChain.focus(nil, visible: false)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 200, height: 300)
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 0)
        }
    }

    @Test("Dragging holds the companion visible through hover leave and release")
    func dragHoldsVisible() throws {
        try chromeScene(root: Harness()) { graph, bar, context, scheduler in
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                             capture: context.pointerCapture, focusChain: context.focusChain)
            let hover = try #require(context.interactions.handlers(for: bar).hover)
            let frame = bar.absoluteFrame
            let point = CGPoint(x: frame.midX, y: frame.minY + 12)
            hover(.enter)
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: Float(point.x), y: Float(point.y), clicks: 1)))
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 1)
            hover(.leave)
            scheduler.tick(deltaTime: 1.0)
            #expect(chromeOpacity(bar) == 1)
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
                button: .left, x: Float(point.x), y: Float(point.y), clicks: 1)))
            scheduler.tick(deltaTime: 1.0)
            // The press focused the bar, so release keeps it visible.
            #expect(chromeOpacity(bar) == 1)
        }
    }

    @Test("Reduced motion snaps visibility without scheduling fades")
    func reducedMotionSnaps() throws {
        try chromeScene(root: ReducedHarness()) { graph, bar, context, scheduler in
            let hover = try #require(context.interactions.handlers(for: bar).hover)
            hover(.enter)
            #expect(scheduler.activeCount == 0)
            #expect(chromeOpacity(bar) == 1)
            hover(.leave)
            #expect(scheduler.activeCount == 0)
            #expect(chromeOpacity(bar) == 0)
            bar.accessibilityActions.increment?()
            graph.recomposer.commitAll()
            graph.computeLayout(width: 200, height: 300)
            #expect(chromeOpacity(bar) == 1)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("Touch-only surfaces keep the companion always visible")
    func touchSurfaceKeepsVisible() throws {
        try chromeScene(root: TouchHarness()) { _, bar, _, _ in
            #expect(chromeOpacity(bar) == 1)
            #expect(drawn(bar))
        }
    }
}
