import Foundation
import GuavaUIRuntime

/// A whole-window reveal from the control that changes appearance. Keyboard
/// and accessibility activation use the same control center as pointer input.
public enum ThemeTransition: Sendable, Equatable {
    case instant
    case circular(duration: Double = 1.0)
}

struct CircularThemeHost<Content: View, Value: Equatable>: _PrimitiveView {
    let theme: Theme
    let value: Value
    let transition: ThemeTransition
    let content: Content

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.addResource(ThemeRevealSession<Value>())
        return node
    }

    func _updateNode(_ node: Node) {
        node.firstResource(ThemeRevealSession<Value>.self)?.configure(
            value: value, transition: transition, node: node)
    }

    func _makeLayoutNode() -> LayoutNode? { nil }

    var _children: [any View] {
        [content.theme(theme)]
    }
}

private final class ThemeRevealSession<Value: Equatable>: NodeResource {
    private var value: Value?
    private var controller: AnimationController<Float>?
    private weak var scheduler: AnimatorScheduler?
    private var sequence: UInt64 = 0

    func mount(node: Node) { scheduler = AnimatorScheduler.current }
    func unmount(node: Node) {
        stop()
        node.requestReveal(nil)
    }

    func configure(value: Value, transition: ThemeTransition, node: Node) {
        guard let previous = self.value else { self.value = value; return }
        if previous == value {
            if node.prefersReducedMotion || transition == .instant {
                stop(); node.requestReveal(nil)
            }
            return
        }
        self.value = value
        stop()
        guard case let .circular(duration) = transition, duration.isFinite, duration > 0,
              !node.prefersReducedMotion else { node.requestReveal(nil); return }
        let bounds = WindowRevealContext.bounds(for: node)
        let origin = WindowRevealContext.activationOrigin(for: node)
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        sequence &+= 1
        let sequence = sequence
        func apply(_ progress: Float, node: Node) {
            let bounds = WindowRevealContext.bounds(for: node)
            let dx = max(abs(origin.x - bounds.minX), abs(origin.x - bounds.maxX))
            let dy = max(abs(origin.y - bounds.minY), abs(origin.y - bounds.maxY))
            node.requestReveal(progress < 1 ? UIReveal(sequence: sequence,
                centerX: Float(origin.x), centerY: Float(origin.y),
                radius: Float((dx * dx + dy * dy).squareRoot()) * progress) : nil)
        }
        apply(0, node: node)
        let clock = AnimationController(from: Float(0), to: Float(1),
            animation: Animation(duration: duration, curve: .cubicBezier(0.4, 0, 0.2, 1))) { [weak node] progress in
            guard let node else { return }
            apply(progress, node: node)
        }
        controller = clock
        scheduler?.register(clock)
    }

    private func stop() {
        if let controller { controller.cancel(); scheduler?.unregister(controller) }
        controller = nil
    }
}
