import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Touch-only surfaces get a thin, overlaid, auto-hiding indicator; pointer
/// surfaces keep the stable gutter and a draggable scrollbar.
@Suite("Scroll indicators by input", .serialized)
struct ScrollIndicatorTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var input: UIEnvironment.Input
        var body: some View {
            var surface = UIEnvironment(); surface.input = input
            return ScrollView(.vertical, scrollbarGutter: .stable) {
                Column {
                    Text("head").frame(width: 200, height: 300)
                    Text("tail").frame(width: 200, height: 300)
                }
            }
            .frame(width: 220, height: 160)
            .surfaceEnvironment(surface)
        }
    }

    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    private func scene(_ input: UIEnvironment.Input,
                       _ body: (ViewGraph, Node, InteractionRegistry, PointerCapture) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let oldText = TextEnvironmentHolder.current
            let oldRegistry = InteractionRegistryHolder.current, oldCapture = PointerCaptureHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            let registry = InteractionRegistry(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry; PointerCaptureHolder.current = capture
            defer {
                TextEnvironmentHolder.current = oldText
                InteractionRegistryHolder.current = oldRegistry; PointerCaptureHolder.current = oldCapture
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Harness(input: input))
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 220, height: 160) }
            let scroll = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .scrollArea })
            try body(graph, scroll, registry, capture)
            graph.install(root: EmptyView())
        }
    }

    private func opacity(_ node: Node) -> Float {
        node.attachments["__scrollview_scrollbar_chrome_opacity"] as? Float ?? -1
    }

    @Test("touch-only content uses the full width; pointer and mixed surfaces keep the 12pt gutter")
    func gutterFollowsInput() throws {
        for (input, gutter) in [(UIEnvironment.Input([.touch]), 0.0), ([.touch, .pointer, .keyboard], 12.0), ([.pointer, .keyboard], 12.0)] {
            try scene(input) { _, scroll, _, _ in
                let content = try #require(scroll.children.first)
                #expect(abs(scroll.frame.width - content.frame.width - gutter) < 0.5, "\(input)")
            }
        }
    }

    @Test("a touch scroll reveals the thin indicator and the pointer lane cannot grab a thumb")
    func touchRevealsIndicator() throws {
        try scene([.touch]) { graph, scroll, registry, capture in
            #expect(opacity(scroll) == 0)
            let motion = try #require(scroll.attachments["__scrollview_motion"] as? ScrollAnimator)
            motion.scrollDirectly(by: CGPoint(x: 0, y: 40))
            #expect(scroll.contentOffset.y > 0)
            #expect(opacity(scroll) == 1)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: FocusChain())
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: 216, y: 20, clicks: 1)))
            #expect(capture.target !== scroll)
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: 216, y: 20, clicks: 1)))
        }
    }

    @Test("pointer surfaces keep hover-revealed, draggable chrome")
    func pointerKeepsDraggableChrome() throws {
        try scene([.pointer, .keyboard]) { graph, scroll, registry, capture in
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: FocusChain())
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: 214, y: 10, clicks: 1)))
            #expect(capture.target === scroll)
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 214, y: 50, deltaX: 0, deltaY: 40)))
            #expect(scroll.contentOffset.y > 0)
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: 214, y: 50, clicks: 1)))
        }
    }
}
