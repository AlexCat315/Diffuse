import Foundation
import GuavaUIRuntime

/// Scrolls the enclosing scroll view while a drag holds the pointer near its
/// top or bottom edge: faster the deeper into the edge zone, and still moving
/// when the pointer rests there or leaves the viewport. Attach it to the drag
/// source's node; it ticks only between `begin` and `end`.
final class EdgeAutoScroll: NodeResource, AnyAnimationController {
    /// Points per second at the very edge.
    static let maximumSpeed: CGFloat = 1_200

    private weak var owner: Node?
    private weak var scroll: Node?
    private var pointerY: CGFloat = 0
    private var startOffset: CGFloat = 0
    private var onScroll: () -> Void = {}
    var isFinished = true

    /// Distance scrolled since `begin`; drags add it to the pointer delta so
    /// positions stay in content coordinates.
    var scrolledDistance: CGFloat { (scroll?.contentOffset.y ?? startOffset) - startOffset }

    func mount(node: Node) { owner = node }
    func unmount(node: Node) { end(); owner = nil }

    /// Starts tracking; `onScroll` runs after every automatic scroll step.
    func begin(pointerY: Float, onScroll: @escaping () -> Void) {
        guard let owner, let scroll = EnclosingScroll.container(of: owner) else { return }
        self.scroll = scroll; self.onScroll = onScroll
        startOffset = scroll.contentOffset.y
        self.pointerY = CGFloat(pointerY)
        if isFinished { isFinished = false; AnimatorScheduler.current.register(self) }
    }

    func update(pointerY: Float) { self.pointerY = CGFloat(pointerY) }

    func end() {
        scroll = nil
        guard !isFinished else { return }
        isFinished = true
        AnimatorScheduler.current.unregister(self)
    }

    func tick(deltaTime: Double) {
        guard !isFinished, let scroll else { return }
        let speed = Self.velocity(pointerY: pointerY, viewport: EnclosingScroll.viewport(of: scroll))
        guard speed != 0, EnclosingScroll.scroll(scroll, byY: speed * CGFloat(deltaTime)) != 0 else { return }
        onScroll()
    }

    func finishImmediately() { end() }
    func cancel() { end() }

    /// Signed speed for a pointer at `pointerY`: zero outside the edge zones,
    /// rising quadratically to the maximum at (or beyond) the edge.
    static func velocity(pointerY: CGFloat, viewport: CGRect) -> CGFloat {
        let zone = min(48, viewport.height / 4)
        guard zone > 0 else { return 0 }
        let top = pointerY - viewport.minY, bottom = viewport.maxY - pointerY
        if top < zone {
            let depth = min(1, (zone - top) / zone)
            return -maximumSpeed * depth * depth
        }
        if bottom < zone {
            let depth = min(1, (zone - bottom) / zone)
            return maximumSpeed * depth * depth
        }
        return 0
    }
}
