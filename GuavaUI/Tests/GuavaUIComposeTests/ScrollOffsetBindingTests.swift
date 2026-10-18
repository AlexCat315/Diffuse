import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Scroll offset binding geometry", .serialized)
struct ScrollOffsetBindingTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var contentHeight: Float = 400
        @State var offset = CGPoint.zero

        var body: some View {
            ScrollView(.vertical, scrollOffset: $offset) {
                Box {}.frame(height: contentHeight).flex(0, shrink: 0)
            }.frame(width: 200, height: 100)
        }
    }

    private struct TimedHarness: View {
        @State var request: ScrollRequest?
        @State var offset = CGPoint.zero
        var body: some View {
            ScrollView(.vertical, scrollOffset: $offset, scrollRequest: request) {
                Box {}.frame(height: 1_000).flex(0, shrink: 0)
            }.frame(width: 200, height: 100)
        }
    }

    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<4 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 300, height: 200)
        }
    }

    @Test("binding offsets use newly laid out content bounds and native wheel input stays direct")
    func contentGrowthAndShrink() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let harness = Harness()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness)
            settle(graph)
            let scroll = try #require(nodes(graph.tree.root).first { $0.attachments[ScrollReveal.handlerKey] != nil })
            harness.$offset.wrappedValue = CGPoint(x: 0, y: 250)
            settle(graph)
            #expect(scroll.contentOffset.y == 250)
            harness.$contentHeight.wrappedValue = 800
            harness.$offset.wrappedValue = CGPoint(x: 0, y: 650)
            settle(graph)
            #expect(scroll.contentOffset.y == 650)
            #expect(harness.offset.y == 650)
            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                        capture: context.pointerCapture, focusChain: context.focusChain)
            input.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1, mouseX: 100, mouseY: 50)))
            let afterWheel = scroll.contentOffset.y
            #expect(afterWheel == 680)
            AnimatorScheduler.current.tick(deltaTime: 0.2)
            #expect(scroll.contentOffset.y == afterWheel)
            let motion = try #require(scroll.attachments["__scrollview_motion"] as? ScrollAnimator)
            #expect(!motion.isGliding)
            harness.$contentHeight.wrappedValue = 180
            harness.$offset.wrappedValue = CGPoint(x: 0, y: 70)
            settle(graph)
            #expect(scroll.contentOffset.y == 70)
            #expect(harness.offset.y == 70)
            harness.$offset.wrappedValue = CGPoint(x: 0, y: 9_000)
            settle(graph)
            #expect(scroll.contentOffset.y == 80)
            #expect(harness.offset.y == 80)
        }
    } }
    @Test("timed scroll requests animate, clamp, cancel on input and honor reduced motion")
    func timedScroll() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let harness = TimedHarness()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness)
            settle(graph)
            let scroll = try #require(nodes(graph.tree.root).first { $0.attachments[ScrollReveal.handlerKey] != nil })

            harness.$request.wrappedValue = ScrollRequest(offset: CGPoint(x: 0, y: 600), duration: 0.2)
            settle(graph)
            AnimatorScheduler.current.tick(deltaTime: 0.1)
            let mid = scroll.contentOffset.y
            #expect(mid > 0 && mid < 600)
            AnimatorScheduler.current.tick(deltaTime: 0.3)
            #expect(scroll.contentOffset.y == 600)
            #expect(harness.offset.y == 600)

            harness.$request.wrappedValue = ScrollRequest(offset: CGPoint(x: 0, y: 900), duration: 0.4)
            settle(graph)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
            let beforeWheel = scroll.contentOffset.y
            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                        capture: context.pointerCapture, focusChain: context.focusChain)
            input.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1, mouseX: 100, mouseY: 50)))
            #expect(scroll.contentOffset.y != beforeWheel)
            AnimatorScheduler.current.tick(deltaTime: 0.5)
            #expect(scroll.contentOffset.y < 900)
        }

        let request = ScrollRequest(offset: CGPoint(x: 0, y: 700), duration: 0.4)
        let reduced = TimedHarness(request: request).reducedMotion()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: reduced)
        settle(graph)
        let scroll = try #require(nodes(graph.tree.root).first { $0.attachments[ScrollReveal.handlerKey] != nil })
        #expect(scroll.contentOffset.y == 700)
    } }

}
