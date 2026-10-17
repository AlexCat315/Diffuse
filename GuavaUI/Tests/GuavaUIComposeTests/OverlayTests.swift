import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Overlay attachment", .serialized)
struct OverlayTests: GuavaUIComposeSerializedSuite {
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

    @Test("Overlay keeps the base size and aligns content inside its bounds")
    func alignment() throws {
        try GlobalTestLock.locked {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Row {
                Box {}.frame(width: 100, height: 40)
                    .overlay(alignment: .topLeading) {
                        Box {}.frame(width: 20, height: 20).debugName("overlay")
                    }
                    .debugName("base")
            })
            graph.computeLayout(width: 300, height: 200)
            let base = try named("base", in: graph)
            let leading = try named("overlay", in: graph)
            #expect(base.frame.size == CGSize(width: 100, height: 40))
            #expect(leading.frame.origin == .zero)

            graph.install(root: Row {
                Box {}.frame(width: 100, height: 40)
                    .overlay {
                        Box {}.frame(width: 20, height: 20).debugName("overlay")
                    }
                    .debugName("base")
            })
            graph.computeLayout(width: 300, height: 200)
            let centered = try named("overlay", in: graph)
            #expect(centered.frame.origin == CGPoint(x: 40, y: 10))
        }
    }

    @Test("Overlay content receives pointer input before the base")
    func hitTesting() {
        withScene { graph, registry, focus, capture in
            var hits: [String] = []
            graph.install(root: Row {
                Button(action: { hits.append("base") }) {
                    Box {}.frame(width: 100, height: 100).background(.accent)
                }
                .overlay {
                    Button(action: { hits.append("overlay") }) {
                        Box {}.frame(width: 60, height: 40).background(.warning)
                    }
                }
            })
            graph.computeLayout(width: 200, height: 200)
            let event = MouseButtonEvent(button: .left, x: 50, y: 50, clicks: 1)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                             capture: capture, focusChain: focus)
            dispatcher.dispatch(.mouseButtonDown(event))
            graph.recomposer.commitAll()
            dispatcher.dispatch(.mouseButtonUp(event))
            #expect(hits == ["overlay"])
        }
    }
}
