import Testing
import CoreGraphics
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 6.4 Button & ScrollView", .serialized)
struct ButtonScrollViewTests: GuavaUIComposeSerializedSuite {

    @Test("Button registers a pointer handler that fires on down+up")
    func buttonFiresOnTap() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var taps = 0
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button(action: { taps += 1 }) {
                Text("OK")
            }
        )

        // Button is now a composite View; the ButtonHost primitive node lives
        // one level below the user-view anchor.
        let buttonNode = tree.root!.children.first!.children.first!
        #expect(buttonNode.isHitTestable == true)
        #expect(buttonNode.isFocusable == true)

        let handlers = registry.handlers(for: buttonNode)
        #expect(handlers.pointer != nil)

        let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
        _ = handlers.pointer!(evt, .down, .target)
        _ = handlers.pointer!(evt, .up,   .target)
        #expect(taps == 1)
    } }

    @Test("Button up without prior down does not fire action")
    func buttonIgnoresStrayUp() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var taps = 0
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button(action: { taps += 1 }) {
                Text("X")
            }
        )

        let handlers = registry.handlers(for: tree.root!.children.first!.children.first!)
        let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
        let result = handlers.pointer!(evt, .up, .target)
        #expect(taps == 0)
        #expect(result == .ignored)
    } }

    @Test("ScrollView is hit-testable, clips, and registers a wheel handler")
    func scrollViewSetup() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("a")
                }
            }
        )

        let sv = tree.root!.children.first!
        #expect(sv.isHitTestable == true)
        #expect(sv.clipsToBounds == true)
        #expect(registry.handlers(for: sv).wheel != nil)
    } }

    @Test("ScrollView wheel handler clamps and updates contentOffset")
    func scrollViewClamps() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    // Fixed-height children that exceed the viewport.
                    Text("a").frame(height: 100)
                    Text("b").frame(height: 100)
                    Text("c").frame(height: 100)
                }
            }
            .frame(height: 150)
        )

        // Force layout so the inner column gets a frame.
        graph.computeLayout(width: 200, height: 400)

        let sv = tree.root!.children.first!
        let inner = sv.children.first!
        // Sanity: viewport 150, content ≥ 300 due to fixed-height children.
        #expect(sv.frame.height == 150)
        #expect(inner.frame.height >= 300)

        let wheel = registry.handlers(for: sv).wheel!

        // Scroll down: y = -10 (SDL3 wheel up = positive y; our convention scrolls
        // content up, i.e. offset.y increases when wheel y is negative).
        _ = wheel(MouseWheelEvent(x: 0, y: -1), .target)
        #expect(sv.contentOffset.y > 0)

        // Try to over-scroll: many notches down.
        for _ in 0..<100 {
            _ = wheel(MouseWheelEvent(x: 0, y: -1), .target)
        }
        // Clamped to contentSize - viewSize.
        let maxOffset = inner.frame.height - sv.frame.height
        #expect(sv.contentOffset.y == maxOffset)

        // Scroll back to 0 and overshoot upward.
        for _ in 0..<100 {
            _ = wheel(MouseWheelEvent(x: 0, y: 1), .target)
        }
        #expect(sv.contentOffset.y == 0)
    } }
}
