import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Applied spring interaction", .serialized)
struct InteractionTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var offset = CGPoint.zero
        @State var enabled = true
        @State var reduced = false
        var body: some View {
            Box {}.frame(width: 100, height: 60).background(.accent)
                .springDrag(offset: $offset, isEnabled: enabled).frame(width: 100, height: 60)
                .absolutePosition(left: 40, top: 30).reducedMotion(reduced)
        }
    }
    @Test("Pointer drag releases with measured velocity and remains hittable at its moving frame")
    func dragRelease() throws { try scene { graph, scheduler, context, dispatcher in
        let harness = Harness(); graph.install(root: harness); settle(graph)
        let node = try dragNode(graph), session = try #require(node.firstResource(SpringDragSession.self))
        var time = 0.0; session.now = { time }
        let down = MouseButtonEvent(button: .left, x: 70, y: 50, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(down)); settle(graph)
        #expect(context.pointerCapture.target === node)
        time = 0.05
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 100, y: 60, deltaX: 30, deltaY: 10))); settle(graph)
        #expect(harness.offset == CGPoint(x: 30, y: 10))
        #expect(node.absoluteFrame.origin == CGPoint(x: 70, y: 40))
        time = 0.1
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 130, y: 70, deltaX: 30, deltaY: 10))); settle(graph)
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: 130, y: 70, clicks: 1))); settle(graph)
        #expect(context.pointerCapture.target == nil && scheduler.activeCount == 1)
        let released = harness.offset
        scheduler.tick(deltaTime: 0.0001); settle(graph)
        #expect(harness.offset.x > released.x && harness.offset.y > released.y)
        #expect(HitTester.hitTest(rootNode: graph.tree.root!, point: node.absoluteFrame.center)?.node === node)
        scheduler.tick(deltaTime: 5); settle(graph)
        #expect(harness.offset == .zero && scheduler.activeCount == 0)
    } }

    @Test("Regrab has no jump; disabling and reducing motion release capture and clear the spring")
    func dragCancellation() throws { try scene { graph, scheduler, context, _ in
        let harness = Harness(); graph.install(root: harness); settle(graph)
        let node = try dragNode(graph), session = try #require(node.firstResource(SpringDragSession.self))
        var time = 0.0; session.now = { time }
        session.begin(at: CGPoint(x: 70, y: 50))
        time = 0.08; session.move(to: CGPoint(x: 130, y: 70)); session.release()
        scheduler.tick(deltaTime: 0.04); settle(graph)
        let displayed = harness.offset
        session.begin(at: node.absoluteFrame.center)
        #expect(harness.offset == displayed && scheduler.activeCount == 0)
        harness.$enabled.wrappedValue = false; settle(graph)
        #expect(context.pointerCapture.target == nil && !session.isDragging)
        #expect(harness.offset == .zero && scheduler.activeCount == 0)
        harness.$enabled.wrappedValue = true; harness.$reduced.wrappedValue = true; settle(graph)
        session.begin(at: CGPoint(x: 70, y: 50))
        time += 0.08; session.move(to: CGPoint(x: 130, y: 70)); session.release(); settle(graph)
        #expect(harness.offset == .zero && scheduler.activeCount == 0)
    } }

    @Test("Button chrome scales on press while the outer activation target remains stable")
    func buttonPress() throws { try scene { graph, scheduler, _, dispatcher in
        var theme = Theme.defaultLight; theme.motion.pressScale = 0.9
        var activations = 0
        graph.install(root: Button("Press") { activations += 1 }.frame(width: 200, height: 44).theme(theme)); settle(graph)
        var chrome: Node?
        for node in nodes(graph.tree.root!) {
            if node.attachments[BuiltinButtonChrome.stateKey] != nil { chrome = node; break }
        }
        let surface = try #require(chrome)
        let event = MouseButtonEvent(button: .left, x: 1, y: 22, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event)); settle(graph)
        scheduler.tick(deltaTime: 0.04); settle(graph)
        #expect(surface.transform.scale < 1 && surface.transform.scale >= 0.89)
        dispatcher.dispatch(.mouseButtonUp(event)); settle(graph)
        #expect(activations == 1)
        scheduler.tick(deltaTime: 5); settle(graph)
        #expect(surface.transform.scale == 1 && scheduler.activeCount == 0)
    } }

    private func scene(_ work: (ViewGraph, AnimatorScheduler, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), scheduler = AnimatorScheduler()
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 10) }
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                try work(graph, scheduler, context, dispatcher)
            } }
        }
    }
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    private func dragNode(_ graph: ViewGraph) throws -> Node {
        var found: Node?
        for node in nodes(graph.tree.root!) { if node.firstResource(SpringDragSession.self) != nil { found = node; break } }
        return try #require(found)
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 400, height: 300) }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
