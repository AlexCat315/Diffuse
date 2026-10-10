#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Rubber-band overscroll as seen through `ScrollView` — the wheel path, the
/// scrollbar drag path, and the `CompositionLocal` override.
///
/// The curve and the spring themselves are covered by the portable unit tests
/// in `GuavaUISceneTests/Scrolling`; what belongs here is that they are wired
/// into the input handlers.
@Suite("ScrollPhysics")
struct ScrollPhysicsTests {

    private func firstNode(in node: Node?,
                           where predicate: (Node) -> Bool) -> Node? {
        guard let node else { return nil }
        if predicate(node) { return node }
        for child in node.children {
            if let match = firstNode(in: child, where: predicate) { return match }
        }
        return nil
    }

    private func absoluteOrigin(of node: Node) -> CGPoint {
        var origin = node.frame.origin
        var current = node.parent
        while let parent = current {
            origin.x += parent.frame.origin.x
            origin.y += parent.frame.origin.y
            current = parent.parent
        }
        return origin
    }

    /// 300pt of content in a 150pt viewport ⇒ `maxOffsetY == 150`.
    private func installedScrollView(
        physics: ScrollPhysics? = nil
    ) -> (Node, InteractionRegistry) {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let scrollView = ScrollView(.vertical) {
            Column {
                Text("a").frame(height: 100)
                Text("b").frame(height: 100)
                Text("c").frame(height: 100)
            }
        }
        .frame(width: 200, height: 150)

        if let physics {
            graph.install(root: scrollView.scrollPhysics(physics))
        } else {
            graph.install(root: scrollView)
        }
        graph.computeLayout(width: 200, height: 400)

        guard let node = firstNode(in: tree.root, where: {
            registry.handlers(for: $0).wheelRoute?.role == .scroll
        }) else {
            fatalError("ScrollView did not register a wheel handler")
        }
        return (node, registry)
    }

    private func tick(frames: Int = 120) {
        for _ in 0..<frames { AnimatorScheduler.current.tick(deltaTime: 1.0 / 60.0) }
    }

    // MARK: - Wheel

    @Test("Wheel past the end stretches past the bound, then springs back")
    func wheelPastTheEndSettlesBack() { GlobalTestLock.locked {
        let (view, registry) = installedScrollView()
        let wheel = registry.handlers(for: view).wheel!

        for _ in 0..<6 { _ = wheel(MouseWheelEvent(x: 0, y: -1), .target) }

        let stretched = view.contentOffset.y
        #expect(stretched > 150)
        // Never further than one viewport past the bound, however hard.
        #expect(stretched < 150 + 150)

        tick()
        #expect(view.contentOffset.y == 150)
    } }

    @Test("Wheel past the start pulls the content below zero and returns")
    func wheelPastTheStartSettlesBack() { GlobalTestLock.locked {
        let (view, registry) = installedScrollView()
        let wheel = registry.handlers(for: view).wheel!

        for _ in 0..<2 { _ = wheel(MouseWheelEvent(x: 0, y: 1), .target) }
        let stretched = view.contentOffset.y
        #expect(stretched < 0)
        #expect(stretched > -60)

        tick()
        #expect(view.contentOffset.y == 0)
    } }

    @Test("Repeated wheel input at the bound stays bounded and still settles")
    func repeatedInputStaysBounded() { GlobalTestLock.locked {
        let (view, registry) = installedScrollView()
        let wheel = registry.handlers(for: view).wheel!

        for _ in 0..<5 { _ = wheel(MouseWheelEvent(x: 0, y: -1), .target) }
        #expect(view.contentOffset.y == 150)

        for _ in 0..<40 {
            _ = wheel(MouseWheelEvent(x: 0, y: -1), .target)
            tick(frames: 2)
            #expect(view.contentOffset.y > 150)
            #expect(view.contentOffset.y < 150 + 150)
        }

        tick()
        #expect(view.contentOffset.y == 150)
    } }

    // MARK: - Scrollbar drag

    @Test("Dragging the thumb past the end holds the stretch until release")
    func scrollbarDragBouncesBackOnRelease() { GlobalTestLock.locked {
        let (view, registry) = installedScrollView()
        let pointer = registry.handlers(for: view).pointer!
        let motion = registry.handlers(for: view).motion!

        let origin = absoluteOrigin(of: view)
        let scrollbarX = Float(origin.x + view.frame.width - 6)
        let thumbY = Float(origin.y + 10)

        #expect(pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY,
                                         clicks: 1), .down, .target) == .handled)
        _ = motion(MouseMotionEvent(x: scrollbarX, y: thumbY + 500,
                                    deltaX: 0, deltaY: 500), .target)

        let stretched = view.contentOffset.y
        #expect(stretched > 150)
        #expect(stretched < 150 + 150)

        // Nothing spring-loaded while the gesture is still held.
        tick(frames: 30)
        #expect(view.contentOffset.y == stretched)

        _ = pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY + 500,
                                     clicks: 1), .up, .target)
        tick()
        #expect(view.contentOffset.y == 150)
    } }

    // MARK: - Overrides

    @Test(".scrollPhysics(.clamped) restores hard clamping")
    func clampedPhysics() { GlobalTestLock.locked {
        let (view, registry) = installedScrollView(physics: .clamped)
        let wheel = registry.handlers(for: view).wheel!

        for _ in 0..<100 { _ = wheel(MouseWheelEvent(x: 0, y: -1), .target) }
        #expect(view.contentOffset.y == 150)

        for _ in 0..<100 { _ = wheel(MouseWheelEvent(x: 0, y: 1), .target) }
        #expect(view.contentOffset.y == 0)
    } }

    @Test(".scrollPhysics(.bouncy) crosses the bound on the way back")
    func bouncyPhysics() { GlobalTestLock.locked {
        let (view, registry) = installedScrollView(physics: .bouncy)
        let wheel = registry.handlers(for: view).wheel!

        for _ in 0..<6 { _ = wheel(MouseWheelEvent(x: 0, y: -1), .target) }
        #expect(view.contentOffset.y > 150)

        var dippedBelowBound = false
        for _ in 0..<180 {
            AnimatorScheduler.current.tick(deltaTime: 1.0 / 60.0)
            if view.contentOffset.y < 149.5 { dippedBelowBound = true }
        }
        #expect(dippedBelowBound)
        #expect(view.contentOffset.y == 150)
    } }
}
