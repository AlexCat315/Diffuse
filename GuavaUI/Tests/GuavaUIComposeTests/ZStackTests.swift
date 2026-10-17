import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("ZStack layering", .serialized)
struct ZStackTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        })
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current, oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry
            FocusChainHolder.current = focus
            PointerCaptureHolder.current = capture
            defer {
                InteractionRegistryHolder.current = oldRegistry
                FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, focus, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    @Test("ZStack measures to its largest child and aligns the rest")
    func measuresAndAligns() throws {
        try GlobalTestLock.locked {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Row {
                ZStack(alignment: .topLeading) {
                    Box {}.frame(width: 100, height: 40).debugName("large")
                    Box {}.frame(width: 20, height: 20).debugName("small")
                }.debugName("stack")
            })
            graph.computeLayout(width: 300, height: 200)
            let stack = try named("stack", in: graph)
            let large = try named("large", in: graph)
            let small = try named("small", in: graph)
            #expect(stack.frame.size == CGSize(width: 100, height: 40))
            #expect(large.frame.origin == .zero)
            #expect(small.frame.origin == .zero)

            graph.install(root: Row {
                ZStack {
                    Box {}.frame(width: 100, height: 40).debugName("large")
                    Box {}.frame(width: 20, height: 20).debugName("small")
                }.debugName("stack")
            })
            graph.computeLayout(width: 300, height: 200)
            let centered = try named("small", in: graph)
            #expect(centered.frame.origin == CGPoint(x: 40, y: 10))
        }
    }

    @Test("ZStack preserves semantic leading in RTL")
    func rtlAlignment() throws {
        try GlobalTestLock.locked {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Row {
                ZStack(alignment: .topLeading) {
                    Box {}.frame(width: 100, height: 40)
                    Box {}.frame(width: 20, height: 20).debugName("small")
                }.debugName("stack").layoutDirection(.rtl)
            })
            graph.computeLayout(width: 300, height: 200)
            let small = try named("small", in: graph)
            #expect(small.frame.origin == CGPoint(x: 80, y: 0))
        }
    }

    @Test("Later children receive pointer input first")
    func topmostChildWinsHitTesting() {
        withScene { graph, registry, focus, capture in
            var hits: [String] = []
            graph.install(root: ZStack {
                Button(action: { hits.append("back") }) {
                    Box {}.frame(width: 100, height: 100).background(.accent)
                }
                Button(action: { hits.append("front") }) {
                    Box {}.frame(width: 100, height: 100).background(.warning)
                }
            }.frame(width: 100, height: 100))
            graph.computeLayout(width: 200, height: 200)
            let event = MouseButtonEvent(button: .left, x: 50, y: 50, clicks: 1)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                             capture: capture, focusChain: focus)
            dispatcher.dispatch(.mouseButtonDown(event))
            graph.recomposer.commitAll()
            dispatcher.dispatch(.mouseButtonUp(event))
            #expect(hits == ["front"])
        }
    }
}


extension ZStackTests {
    @Test("Card content stays inside its own Box instead of a padded sibling")
    func cardContentStaysInsideItsBox() throws {
        let prior = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = prior }
        try GlobalTestLock.locked {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: ZStack(alignment: .topLeading) {
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Text("Top-left layer").font(.bodyStrong).debugName("label")
                }.frame(width: 120, height: 72).background(.accent).debugName("accent")
            }.frame(width: 320, height: 180))
            graph.computeLayout(width: 320, height: 180)
            let accent = try named("accent", in: graph)
            let label = try named("label", in: graph)
            #expect(label.absoluteFrame.minX >= accent.absoluteFrame.minX)
            #expect(label.absoluteFrame.maxX <= accent.absoluteFrame.maxX)
            #expect(label.absoluteFrame.minY >= accent.absoluteFrame.minY)
            #expect(label.absoluteFrame.maxY <= accent.absoluteFrame.maxY)
        }
    }
}
