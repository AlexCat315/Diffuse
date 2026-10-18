import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("List refresh", .serialized)
struct RefreshTests: GuavaUIComposeSerializedSuite {
    private final class Model {
        var refreshes = 0
    }

    private struct Harness: View {
        let model: Model
        @State var isRefreshing = false

        var body: some View {
            List(0..<20, id: \.self, selection: .constant(0),
                 refresh: RefreshOptions(isRefreshing: $isRefreshing, threshold: 64) {
                model.refreshes += 1
                isRefreshing = true
            }) { index, _ in
                Text("Row \(index + 1)")
            }
            .frame(width: 320, height: 300)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<20 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 360, height: 360)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    private func scene(nested: Bool = false, _ body: (ViewGraph, PlatformInputContext, EventDispatcher, Harness) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            try context.withCurrent {
                var environment = UIEnvironment()
                environment.viewport.width = 360
                environment.input = [.touch, .keyboard]
                let model = Model()
                let harness = Harness(model: model)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                 capture: context.pointerCapture,
                                                 focusChain: context.focusChain)
                let root: AnyView
                if nested {
                    root = AnyView(ScrollView(.vertical) {
                        Column {
                            harness
                            Text("Outer content").frame(height: 400)
                        }
                    }.frame(width: 360, height: 360))
                } else {
                    root = AnyView(harness)
                }
                graph.install(root: root.surfaceEnvironment(environment))
                settle(graph)
                defer { graph.install(root: EmptyView()) }
                try body(graph, context, dispatcher, harness)
            }
        }
    }

    @Test("A nested touch list refreshes without its parent stealing the drag")
    func nestedPull() throws {
        try scene(nested: true) { graph, _, dispatcher, harness in
            let scrolls = nodes(graph.tree.root!).filter { $0.attachments[ScrollReveal.handlerKey] != nil }
            #expect(scrolls.count == 2)
            let inner = try #require(scrolls.last)
            let point = inner.absoluteFrame.origin
            let x = Float(point.x + 100), y = Float(point.y + 10)
            dispatcher.dispatch(.mouseButtonDown(.init(button: .left, x: x, y: y, clicks: 1)))
            dispatcher.dispatch(.mouseMotion(.init(x: x, y: y + 50, deltaX: 0, deltaY: 50)))
            dispatcher.dispatch(.mouseMotion(.init(x: x, y: y + 220, deltaX: 0, deltaY: 170)))
            settle(graph)
            #expect(harness.model.refreshes == 1)
            #expect(inner.contentOffset.y < 0)
            #expect(scrolls.first?.contentOffset == .zero)
            dispatcher.dispatch(.mouseButtonUp(.init(button: .left, x: x, y: y + 220, clicks: 1)))
        }
    }

    private func indicator(_ graph: ViewGraph) -> Node? {
        nodes(graph.tree.root!).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "refresh-indicator"
        }
    }

    private func indicatorVisible(_ graph: ViewGraph) -> Bool {
        guard var node = indicator(graph) else { return false }
        while true {
            if node.opacity < 0.5 { return false }
            guard let parent = node.parent else { return true }
            node = parent
        }
    }

    @Test("A touch pull crosses the threshold once and holds the indicator until done")
    func pull() throws {
        try scene { graph, _, dispatcher, harness in
            let scroll = try #require(nodes(graph.tree.root!).first {
                $0.attachments[ScrollReveal.handlerKey] != nil
            })
            let x: Float = 160, y: Float = 30
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: x, y: y, clicks: 1)))
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
                x: x, y: y + 220, deltaX: 0, deltaY: 220)))
            settle(graph)
            #expect(harness.model.refreshes == 1)
            #expect(scroll.contentOffset.y < 0)
            #expect(indicatorVisible(graph))
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
                button: .left, x: x, y: y + 220, clicks: 1)))
            settle(graph)
            #expect(harness.model.refreshes == 1)
            #expect(indicatorVisible(graph))
            harness.$isRefreshing.wrappedValue = false
            settle(graph)
            #expect(!indicatorVisible(graph))
        }
    }

    @Test("Cmd+R is the keyboard refresh path and does not double-trigger")
    func keyboard() throws {
        try scene { graph, context, dispatcher, harness in
            let scroll = try #require(nodes(graph.tree.root!).first {
                $0.attachments[ScrollReveal.handlerKey] != nil
            })
            context.focusChain.focus(scroll)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.r, keycode: 0,
                                                  modifiers: [.gui], isRepeat: false)))
            settle(graph)
            #expect(harness.model.refreshes == 1)
            #expect(indicatorVisible(graph))
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.r, keycode: 0,
                                                  modifiers: [.gui], isRepeat: false)))
            settle(graph)
            #expect(harness.model.refreshes == 1)
        }
    }
}
