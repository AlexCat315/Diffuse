#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Platform wheel and scrollbar placement must stay direct, even when custom
/// gesture physics are configured through CompositionLocal. Custom inertia
/// and spring curves are also covered by GuavaUISceneTests/Scrolling.
@Suite("ScrollPhysics")
struct ScrollPhysicsTests {

    /// Drives frames and time deterministically, including silence that must
    /// not launch a second fling after platform input.
    private final class ManualClock {
        var now: TimeInterval = 0
    }

    /// One installed `ScrollView` plus everything needed to drive its motion.
    private struct Fixture {
        let view: Node
        let animator: ScrollAnimator
        let clock: ManualClock

        /// Feed the tree one wheel sample, as the platform does.
        func wheel(x: Float = 0, y: Float, input: ScrollInput = .init()) {
            clock.now += 1.0 / 60.0
            let handler = handlers.wheel!
            _ = handler(MouseWheelEvent(x: x, y: y, input: input), .target)
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

    @Test("Line wheel clamps at the end without adding elastic motion")
    func wheelClampsAtEnd() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        for _ in 0..<6 { fixture.wheel(y: -1) }

        #expect(fixture.contentOffset == 150)

        fixture.tick()
        #expect(fixture.contentOffset == 150)
    } }

    @Test("Line wheel clamps at the start")
    func wheelClampsAtStart() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        for _ in 0..<2 { fixture.wheel(y: 1) }
        #expect(fixture.contentOffset == 0)

        fixture.tick()
        #expect(fixture.contentOffset == 0)
    } }

    @Test("Repeated wheel input at the bound stays bounded after silence")
    func repeatedInputStaysBounded() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        for _ in 0..<5 { fixture.wheel(y: -1) }
        #expect(fixture.contentOffset == 150)

        for _ in 0..<40 {
            fixture.wheel(y: -1)
            fixture.tick(frames: 2)
            #expect(fixture.contentOffset == 150)
            #expect(fixture.contentOffset < 150 + 150)
        }

        fixture.tick()
        #expect(fixture.contentOffset == 150)
    } }

    // MARK: - Momentum

    @Test("Line wheel bursts never infer motion after silence, including uneven input gaps")
    func wheelStopsWithInput() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 40)
        var expected: CGFloat = 0
        for gap in [0.016, 0.018, 0.016, 0.12, 0.016, 0.15] {
            fixture.wheel(y: -1)
            expected += 30
            fixture.tick(frames: max(1, Int((gap * 60).rounded(.up))))
            #expect(fixture.contentOffset == expected)
            #expect(fixture.animator.isFinished)
        }
        let delivered = fixture.contentOffset
        #expect(delivered == 180)
        fixture.tick(frames: 600)
        #expect(fixture.contentOffset == delivered)
    } }

    @Test("Precise points and OS momentum are followed once with no second fling")
    func platformMomentumIsNotSynthesizedAgain() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 40)
        fixture.wheel(y: -12.5, input: .init(unit: .points, device: .continuous, phase: .began))
        #expect(fixture.contentOffset == 12.5)
        for delta: Float in [-8, -4, -2, -0.5] {
            fixture.wheel(y: delta, input: .init(unit: .points, device: .continuous, momentumPhase: .changed))
        }
        fixture.wheel(y: 0, input: .init(unit: .points, momentumPhase: .ended))
        #expect(fixture.contentOffset == 27)
        fixture.tick(frames: 600)
        #expect(fixture.contentOffset == 27)
        #expect(fixture.animator.isFinished)
        fixture.wheel(y: 2.25, input: .init(unit: .points, phase: .began))
        #expect(fixture.contentOffset == 24.75)
    } }

    @Test("Page units use the actual logical viewport")
    func pageUnits() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 40)
        fixture.wheel(y: -1, input: .init(unit: .pages))
        #expect(fixture.contentOffset == 150)
    } }

    @Test("A notch while content is coasting stops it for good")
    func notchDuringCoastStopsIt() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 40)
        for _ in 0..<5 {
            fixture.clock.now += 1.0 / 60
            fixture.animator.scroll(by: CGPoint(x: 0, y: 30))
        }

        fixture.tick(frames: 30)
        #expect(fixture.animator.isGliding)

        // One notch: "here". It has to stop the coast and not start another.
        fixture.wheel(y: -1)
        let braked = fixture.contentOffset
        #expect(!fixture.animator.isGliding)

        fixture.tick(frames: 600)
        #expect(fixture.contentOffset == braked)
    } }

    @Test("Pressing inside the container grabs coasting content")
    func pressStopsTheCoast() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 40)
        for _ in 0..<5 {
            fixture.clock.now += 1.0 / 60
            fixture.animator.scroll(by: CGPoint(x: 0, y: 30))
        }

        fixture.tick(frames: 30)
        #expect(fixture.animator.isGliding)
        let origin = absoluteOrigin(of: fixture.view)

        // Anywhere inside, not just on the scrollbar: the press must still
        // reach whatever is under the pointer.
        let result = fixture.pointer(
            MouseButtonEvent(button: .left, x: Float(origin.x + 40), y: Float(origin.y + 40),
                             clicks: 1), phase: .down)
        #expect(result != .handled)
        #expect(!fixture.animator.isGliding)
        let caught = fixture.contentOffset

        fixture.tick(frames: 200)
        #expect(fixture.contentOffset == caught)
    } }

    @Test("System momentum reaching the edge does not add a competing return spring")
    func platformMomentumStopsAtEdge() { GlobalTestLock.locked {
        let fixture = installedScrollView(rows: 4)
        for _ in 0..<20 {
            fixture.wheel(y: -30, input: .init(unit: .points, momentumPhase: .changed))
            fixture.tick(frames: 1)
            #expect(fixture.contentOffset <= 250)
            #expect(!fixture.animator.isSettling)
        }
        #expect(fixture.contentOffset == 250)
        fixture.tick()
        #expect(fixture.contentOffset == 250)
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

    @Test("Wheel input does not synthesize inertia under clamped physics")
    func clampedStopsAtTheEdge() { GlobalTestLock.locked {
        let fixture = installedScrollView(physics: .clamped, rows: 4)
        for _ in 0..<3 { fixture.wheel(y: -1) }

        let maximumOffset = CGFloat(4 * 100 - 150)
        for _ in 0..<600 {
            fixture.tick(frames: 1)
            #expect(fixture.contentOffset <= maximumOffset)
        }
        #expect(fixture.contentOffset == 90)
    } }

    // MARK: - Scrollbar drag

    @Test("Dragging a scrollbar thumb clamps at its absolute range")
    func scrollbarDragClamps() { GlobalTestLock.locked {
        let fixture = installedScrollView()
        let origin = absoluteOrigin(of: fixture.view)
        let scrollbarX = Float(origin.x + fixture.view.frame.width - 6)
        let thumbY = Float(origin.y + 10)

        #expect(fixture.pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY,
                                                clicks: 1), phase: .down) == .handled)
        fixture.motion(MouseMotionEvent(x: scrollbarX, y: thumbY + 500,
                                        deltaX: 0, deltaY: 500))

        let stretched = fixture.contentOffset
        #expect(stretched == 150)
        #expect(stretched < 150 + 150)

        // Nothing spring-loaded while the gesture is still held.
        fixture.tick(frames: 30)
        #expect(fixture.contentOffset == stretched)

        _ = fixture.pointer(MouseButtonEvent(button: .left, x: scrollbarX, y: thumbY + 500,
                                            clicks: 1), phase: .up)
        fixture.tick()
        #expect(fixture.contentOffset == 150)
    } }

    @Test("Releasing a scrollbar thumb keeps the chosen position")
    func scrollbarReleaseStaysPlaced() { GlobalTestLock.locked {
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
        #expect(!fixture.animator.isGliding)
        fixture.tick(frames: 900)
        #expect(fixture.contentOffset == released)
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

    @Test("Custom low-level gestures retain bouncy physics without changing wheel semantics")
    func bouncyPhysics() { GlobalTestLock.locked {
        let fixture = installedScrollView(physics: .bouncy)
        for _ in 0..<6 { fixture.animator.scroll(by: CGPoint(x: 0, y: 30)) }
        #expect(fixture.contentOffset > 150)

        var dippedBelowBound = false
        for _ in 0..<180 {
            fixture.tick(frames: 1)
            if fixture.contentOffset < 149.5 { dippedBelowBound = true }
        }
        #expect(dippedBelowBound)
        #expect(fixture.contentOffset == 150)
    } }
    @Test("Click cancels a custom gesture pending throw")
    func pointerCancelsPendingThrow() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let fixture = installedScrollView(rows: 20)
            for _ in 0..<6 {
                fixture.clock.now += 1.0 / 60
                fixture.animator.scroll(by: CGPoint(x: 0, y: 6))
            }
            let held = fixture.contentOffset
            _ = fixture.pointer(MouseButtonEvent(button: .left, x: 60, y: 60, clicks: 1), phase: .down)
            fixture.tick()
            #expect(fixture.contentOffset == held)
            #expect(fixture.animator.isFinished)
        }
    } }

    @Test("Removing a scrolling subtree immediately releases its scheduler entry")
    func unmountCancelsMotion() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let fixture = installedScrollView(rows: 20)
            for _ in 0..<6 {
                fixture.clock.now += 1.0 / 60
                fixture.animator.scroll(by: CGPoint(x: 0, y: 6))
            }
            #expect(scheduler.activeCount == 1)
            let parent = fixture.view.parent ?? Node()
            if fixture.view.parent == nil { parent.addChild(fixture.view) }
            parent.removeChild(fixture.view)
            #expect(scheduler.activeCount == 0)
            let held = fixture.contentOffset
            fixture.tick()
            #expect(fixture.contentOffset == held)
        }
    } }

    @Test("Nested edge consumes outward input while its axis has overflow")
    func nestedBoundaryContainsInput() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: ScrollView {
            Box(direction: .column, alignItems: .stretch) {
                ScrollView { Box {}.frame(height: 500) }.frame(height: 150).debugName("inner-scroll")
                Box {}.frame(height: 600)
            }.flex(0, shrink: 0)
        }.frame(width: 200, height: 300))
        graph.computeLayout(width: 200, height: 300)
        let inner = firstNode(in: tree.root, where: { ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String) == "inner-scroll" })!
        let result = registry.handlers(for: inner).wheel!(MouseWheelEvent(x: 0, y: 1), .target)
        #expect(result == .handled)
        #expect(inner.contentOffset == .zero)
        #expect(registry.handlers(for: inner).wheel!(MouseWheelEvent(x: 0, y: -1), .target) == .handled)
        #expect(inner.contentOffset.y > 0)
    } }

    @Test("Reduced motion removes added momentum and elastic displacement")
    func reducedMotionScrollsPrecisely() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: ScrollView { Box {}.frame(height: 800) }
            .frame(width: 200, height: 150).reducedMotion())
        graph.computeLayout(width: 200, height: 150)
        let node = firstNode(in: tree.root, where: { registry.handlers(for: $0).wheel != nil })!
        let animator = node.attachments.values.compactMap { $0 as? ScrollAnimator }.first!
        #expect(!animator.physics.momentum.isEnabled)
        #expect(!animator.physics.rubberBand.isEnabled)
        for _ in 0..<6 { _ = registry.handlers(for: node).wheel!(MouseWheelEvent(x: 0, y: -1), .target) }
        #expect(animator.isFinished)
        #expect(node.contentOffset.y == 180)
    } }

}
