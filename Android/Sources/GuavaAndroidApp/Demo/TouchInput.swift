import Foundation
import GuavaUIRuntime

/// Classifies a primary touch as a control drag or a scroll gesture.
final class TouchInput {
    private var down = SIMD2<Float>.zero
    private var previous = SIMD2<Float>.zero
    private var scrolling = false

    func route(kind: Int32, point: SIMD2<Float>, tree: NodeTree,
               context: PlatformInputContext, dispatcher: EventDispatcher) {
        let button = MouseButtonEvent(button: .left, x: point.x, y: point.y, clicks: 1)
        func wheel(_ delta: SIMD2<Float>, _ phase: ScrollPhase) {
            dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: delta.x, y: delta.y, mouseX: down.x, mouseY: down.y,
                input: ScrollInput(unit: .points, device: .continuous, phase: phase,
                                   timestamp: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000))))
        }
        switch kind {
        case 0:
            down = point; previous = point; scrolling = false
            dispatcher.dispatch(.mouseButtonDown(button))
        case 2:
            let delta = point - previous
            if !scrolling && abs(point.x - down.x) + abs(point.y - down.y) > 8,
               let root = tree.root, let hit = HitTester.hitTest(rootNode: root, point: CGPoint(x: CGFloat(down.x), y: CGFloat(down.y))) {
                let capture = context.pointerCapture.target
                let draggingControl = capture.map { context.interactions.handlers(for: $0).motion != nil } ?? false
                var node: Node? = hit.node
                var canScroll = false
                while let current = node {
                    if context.interactions.handlers(for: current).wheelRoute?.role == .scroll { canScroll = true; break }
                    node = current.parent
                }
                if canScroll && !draggingControl {
                    context.pointerCapture.release()
                    scrolling = true
                    wheel(point - down, .began)
                }
            } else if scrolling { wheel(delta, .changed) }
            if !scrolling { dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: point.x, y: point.y, deltaX: delta.x, deltaY: delta.y))) }
            previous = point
        case 1:
            if scrolling { wheel(.zero, .ended) }
            else { dispatcher.dispatch(.mouseButtonUp(button)) }
            scrolling = false
        case 3:
            if scrolling { wheel(.zero, .cancelled) }
            context.pointerCapture.release(); scrolling = false
        default: break
        }
    }
}
