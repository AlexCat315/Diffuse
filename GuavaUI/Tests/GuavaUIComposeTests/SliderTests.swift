import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 8 Slider", .serialized)
struct SliderTests: GuavaUIComposeSerializedSuite {

    /// Walk down two anchor nodes (Slider → _StatefulSlider → SliderHost).
    private func host(in tree: NodeTree) -> Node {
        tree.root!.children.first!.children.first!.children.first!
    }

    private func makeBinding(_ initial: Double) -> (Binding<Double>, () -> Double) {
        var storage = initial
        let binding = Binding<Double>(
            get: { storage },
            set: { storage = $0 }
        )
        return (binding, { storage })
    }

    @Test("Slider materialises a hit-testable, focusable host node")
    func materialise() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, _) = makeBinding(0.5)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Slider(value: binding))

        let h = host(in: tree)
        #expect(h.isHitTestable == true)
        #expect(h.isFocusable == true)
        #expect(registry.handlers(for: h).pointer != nil)
        #expect(registry.handlers(for: h).motion != nil)
        #expect(registry.handlers(for: h).hover != nil)
    } }

    @Test("Pointer down at the right edge writes the upper-bound value")
    func pointerDownWritesValue() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(0)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Slider(value: binding, range: 0...1))
        graph.computeLayout(width: 200, height: 24)

        let h = host(in: tree)
        let width = Float(h.frame.width)
        #expect(width > 0)

        let pointer = registry.handlers(for: h).pointer!
        let down = MouseButtonEvent(button: .left, x: width, y: 12, clicks: 1)
        _ = pointer(down, .down, .target)
        #expect(read() == 1.0)
    } }

    @Test("Pointer outside the host frame clamps to the range bounds")
    func clampsOutOfBounds() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(0.5)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Slider(value: binding, range: 0...10))
        graph.computeLayout(width: 200, height: 24)

        let h = host(in: tree)
        let width = Float(h.frame.width)
        let pointer = registry.handlers(for: h).pointer!

        _ = pointer(MouseButtonEvent(button: .left, x: -50, y: 12, clicks: 1), .down, .target)
        #expect(read() == 0)

        _ = pointer(MouseButtonEvent(button: .left, x: width + 50, y: 12, clicks: 1), .down, .target)
        #expect(read() == 10)
    } }

    @Test("step quantises writes onto the step grid")
    func stepSnapping() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(0)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Slider(value: binding, range: 0...1, step: 0.25))
        graph.computeLayout(width: 200, height: 24)

        let h = host(in: tree)
        let width = Float(h.frame.width)
        let pointer = registry.handlers(for: h).pointer!

        // 30% of width → raw 0.30 → snapped to 0.25.
        _ = pointer(MouseButtonEvent(button: .left, x: width * 0.30, y: 12, clicks: 1), .down, .target)
        #expect(read() == 0.25)

        // 60% → raw 0.60 → snapped to 0.50.
        _ = pointer(MouseButtonEvent(button: .left, x: width * 0.60, y: 12, clicks: 1), .down, .target)
        #expect(read() == 0.50)
    } }

    @Test("Drag through motion updates the binding while pressed")
    func dragUpdatesValue() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(0)
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: Slider(value: binding, range: 0...100))
        graph.computeLayout(width: 200, height: 24)

        let h = host(in: tree)
        let width = Float(h.frame.width)

        let pointer = registry.handlers(for: h).pointer!
        _ = pointer(MouseButtonEvent(button: .left, x: 0, y: 12, clicks: 1), .down, .target)
        recomp.commitAll()

        // Re-read handlers — the recompose may have re-registered them with a
        // freshly captured `isPressed = true` snapshot.
        let motion = registry.handlers(for: h).motion!
        _ = motion(MouseMotionEvent(x: width * 0.5, y: 12, deltaX: 0, deltaY: 0), .target)
        #expect(read() == 50)

        _ = motion(MouseMotionEvent(x: width, y: 12, deltaX: 0, deltaY: 0), .target)
        #expect(read() == 100)
    } }

    @Test("Disabled slider ignores pointer down")
    func disabledIgnoresInput() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let (binding, read) = makeBinding(0.25)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Slider(value: binding, range: 0...1, isEnabled: false))
        graph.computeLayout(width: 200, height: 24)

        let h = host(in: tree)
        // No handler registered when isEnabled=false.
        #expect(registry.handlers(for: h).pointer == nil)
        #expect(read() == 0.25)
    } }

    @Test("PointerCapture is acquired on press and released on release")
    func capturePairing() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        let capture = PointerCapture()
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = nil }

        let (binding, _) = makeBinding(0)
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Slider(value: binding))
        graph.computeLayout(width: 200, height: 24)

        let h = host(in: tree)
        let pointer = registry.handlers(for: h).pointer!
        let evt = MouseButtonEvent(button: .left, x: 0, y: 12, clicks: 1)

        _ = pointer(evt, .down, .target)
        #expect(capture.target === h)

        _ = pointer(evt, .up, .target)
        #expect(capture.target == nil)
    } }
}
