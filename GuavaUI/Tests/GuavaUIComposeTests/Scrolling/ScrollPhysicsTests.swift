#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Inertia, rubber band and the return spring as seen through `ScrollView` —
/// the wheel path, the scrollbar drag path, and the `CompositionLocal`
/// override.
///
/// The curves themselves are covered by the portable unit tests in
/// `GuavaUISceneTests/Scrolling`; what belongs here is that they are wired into
/// the input handlers.
@Suite("ScrollPhysics")
struct ScrollPhysicsTests {

    /// Drives frames and time together. Both the idle window that decides a
    /// wheel gesture has ended and the glide itself are defined in seconds, so
    /// real time would make these tests race against the wall clock.
    private final class ManualClock {
        var now: TimeInterval = 0
    }

    /// One installed `ScrollView` plus everything needed to drive its motion.
    private struct Fixture {
        let view: Node
        let animator: ScrollAnimator
        let clock: ManualClock

        /// Feed the tree one wheel sample, as the platform does.
        func wheel(x: Float = 0, y: Float) {
            clock.now += 1.0 / 60.0
            let handler = handlers.wheel!
            _ = handler(MouseWheelEvent(x: x, y: y), .target)
        }

        func pointer(_ event: MouseButtonEvent, phase: PointerPhase) -> EventResult {
            handlers.pointer!(event, phase, .target)
        }

        func motion(_ event: MouseMotionEvent) {
            clock.now += 1.0 / 60.0
            _ = handlers.motion!(event, .target)
        }

        func tick(frames: Int = 240, interval: TimeInterval = 1.0 / 60.0) {
            for _ in 0..<frames {
                clock.now += interval
                AnimatorScheduler.current.tick(deltaTime: interval)
            }
        }

        var contentOffset: CGFloat { view.contentOffset.y }

        private var handlers: InteractionRegistry.Handlers { registry.handlers(for: view) }
        private let registry: InteractionRegistry

        init(_ pack: (Node, InteractionRegistry, ScrollAnimator, ManualClock)) {
            self.view = pack.0
            self.registry = pack.1
            self.animator = pack.2
            self.clock = pack.3
        }
    }

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

    /// Installs `rows` rows of 100pt in a 150pt viewport — content taller by
    /// `rows * 100 - 150` than the viewport, which is the room a glide has.
    private func installedScrollView(physics: ScrollPhysics? = nil,
                                     rows: Int = 3) -> Fixture {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let scrollView = ScrollView(.vertical) {
            Column {
                Text("content").frame(width: 200, height: Float(rows) * 100)
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
        guard let animator = node.attachments.values
            .compactMap({ $0 as? ScrollAnimator }).first else {
            fatalError("ScrollView did not attach a motion animator")
        }
        let clock = ManualClock()
        animator.clock = { clock.now }
        return Fixture((node, registry, animator, clock))
    }

    // MARK: - Rubber band

    @Test("Wheel past the end stretches past the bound, then springs back")
    func wheelPastTheEndSettlesBack() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        for _ in 0..<6 { fixture.wheel(y: -1) }

        let stretched = fixture.contentOffset
        #expect(stretched > 150)
        // Never further than one viewport past the bound, however hard.
        #expect(stretched < 150 + 150)

        fixture.tick()
        #expect(fixture.contentOffset == 150)
    } }

    @Test("Wheel past the start pulls the content below zero and returns")
    func wheelPastTheStartSettlesBack() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        for _ in 0..<2 { fixture.wheel(y: 1) }
        let stretched = fixture.contentOffset
        #expect(stretched < 0)
        #expect(stretched > -60)

        fixture.tick()
        #expect(fixture.contentOffset == 0)
    } }

    @Test("Repeated wheel input at the bound stays bounded and still settles")
    func repeatedInputStaysBounded() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        for _ in 0..<5 { fixture.wheel(y: -1) }
        #expect(fixture.contentOffset == 150)

        for _ in 0..<40 {
            fixture.wheel(y: -1)
            fixture.tick(frames: 2)
            #expect(fixture.contentOffset > 150)
            #expect(fixture.contentOffset < 150 + 150)
        }

        fixture.tick()
        #expect(fixture.contentOffset == 150)
    } }

    // MARK: - Momentum

    @Test("Content keeps travelling after the wheel stops")
    func wheelCoastsOnceInputStops() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 40)
        for _ in 0..<3 { fixture.wheel(y: -1) }
        let delivered = fixture.contentOffset
        #expect(delivered == 90)

        // Still inside the quiet window — nothing has budgeted yet.
        fixture.tick(frames: 1)
        #expect(fixture.contentOffset == delivered)
        #expect(!fixture.animator.isGliding)

        fixture.tick(frames: 600)
        let coasted = fixture.contentOffset
        #expect(coasted > delivered + 400)
        #expect(coasted < 40 * 100 - 150) // room left in the range
        #expect(fixture.animator.isFinished)
    } }

    @Test("A throw into the end of the range rebounds instead of sticking")
    func throwIntoTheEndRebounds() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 10)
        let maximumOffset = CGFloat(10 * 100 - 150)
        for _ in 0..<3 { fixture.wheel(y: -1) }

        var furthest: CGFloat = 0
        for _ in 0..<600 {
            fixture.tick(frames: 1)
            furthest = max(furthest, fixture.contentOffset)
        }
        #expect(furthest > maximumOffset)
        #expect(fixture.contentOffset == maximumOffset)
        #expect(fixture.animator.isFinished)
    } }

    @Test("Deliberate slow notches rest where they land")
    func slowNotchesDoNotCoast() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 40)
        fixture.clock.now += 0.5
        fixture.wheel(y: -1)
        fixture.clock.now += 0.5
        fixture.wheel(y: -1)

        fixture.tick(frames: 600)
        #expect(fixture.contentOffset == 60)
    } }

    @Test(".precise lands every notch and nothing else")
    func preciseDoesNotCoast() { GlobalTestLock.locked {
        let fixture = installedScrollView(physics: .precise, rows: 40)
        for _ in 0..<3 { fixture.wheel(y: -1) }

        fixture.tick(frames: 600)
        #expect(fixture.contentOffset == 90)
    } }

    @Test(".clamped coasts but stops dead at the edge")
    func clampedStopsAtTheEdge() { GlobalTestLock.locked {
        let fixture = installedScrollView(physics: .clamped, rows: 10)
        for _ in 0..<3 { fixture.wheel(y: -1) }

        let maximumOffset = CGFloat(10 * 100 - 150)
        for _ in 0..<600 {
            fixture.tick(frames: 1)
            #expect(fixture.contentOffset <= maximumOffset)
        }
        #expect(fixture.contentOffset == maximumOffset)
    } }

    // MARK: - Scrollbar drag

    @Test("Dragging the thumb past the end holds the stretch until release")
    func scrollbarDragBouncesBackOnRelease() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        let origin = absoluteOrigin(of: fixture.view)
        let scrollbarX = Float(origin.x + fixture.view.frame.width - 6)
        let thumbY = Float(origin.y + 10)

        #expect(fixture.pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY,
                                                clicks: 1), phase: .down) == .handled)
        fixture.motion(MouseMotionEvent(x: scrollbarX, y: thumbY + 500,
                                        deltaX: 0, deltaY: 500))

        let stretched = fixture.contentOffset
        #expect(stretched > 150)
        #expect(stretched < 150 + 150)

        // Nothing spring-loaded while the gesture is still held.
        fixture.tick(frames: 30)
        #expect(fixture.contentOffset == stretched)

        _ = fixture.pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY + 500,
                                            clicks: 1), phase: .up)
        fixture.tick()
        #expect(fixture.contentOffset == 150)
    } }

    @Test("Flicking the thumb keeps the content moving after release")
    func scrollbarFlickCoasts() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 10)
        let origin = absoluteOrigin(of: fixture.view)
        let scrollbarX = Float(origin.x + fixture.view.frame.width - 6)
        let thumbY = Float(origin.y + 10)

        #expect(fixture.pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY,
                                                clicks: 1), phase: .down) == .handled)
        // A short, quick stroke: long enough to leave the range untouched.
        for step in 1...8 {
            fixture.motion(MouseMotionEvent(x: scrollbarX, y: thumbY + Float(step) * 2,
                                            deltaX: 0, deltaY: 2))
        }
        let released = fixture.contentOffset
        #expect(released > 0)
        #expect(released < 10 * 100 - 150)

        _ = fixture.pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY + 16,
                                            clicks: 1), phase: .up)
        #expect(fixture.animator.isGliding)
        fixture.tick(frames: 900)
        #expect(fixture.contentOffset > released + 100)
        #expect(fixture.animator.isFinished)
    } }

    // MARK: - Overrides

    @Test(".scrollPhysics(.clamped) restores hard clamping")
    func clampedPhysics() { GlobalTestLock.locked {
        let fixture = installedScrollView(physics: .clamped)
        for _ in 0..<100 { fixture.wheel(y: -1) }
        #expect(fixture.contentOffset == 150)

        for _ in 0..<100 { fixture.wheel(y: 1) }
        #expect(fixture.contentOffset == 0)
    } }

    @Test(".scrollPhysics(.bouncy) crosses the bound on the way back")
    func bouncyPhysics() { GlobalTestLock.locked {
        let fixture = installedScrollView(physics: .bouncy)
        for _ in 0..<6 { fixture.wheel(y: -1) }
        #expect(fixture.contentOffset > 150)

        var dippedBelowBound = false
        for _ in 0..<180 {
            fixture.tick(frames: 1)
            if fixture.contentOffset < 149.5 { dippedBelowBound = true }
        }
        #expect(dippedBelowBound)
        #expect(fixture.contentOffset == 150)
    } }
}
