import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

public extension View {
    /// Direct manipulation followed by a velocity-preserving spring release.
    /// Offset is in the parent's logical points; input remains at the drawn frame.
    func springDrag(offset: Binding<CGPoint>, restingAt target: CGPoint = .zero,
                    spring: SpringSolution = SpringSolution(response: 0.4, dampingFraction: 0.82),
                    isEnabled: Bool = true) -> some View {
        SpringDragHost(offset: offset, target: target, spring: spring, isEnabled: isEnabled, content: self)
    }
}
private struct SpringDragHost<Content: View>: _PrimitiveView {
    let offset: Binding<CGPoint>
    let target: CGPoint
    let spring: SpringSolution
    let isEnabled: Bool
    let content: Content
    func _makeNode() -> Node {
        let node = Node(); node.addResource(SpringDragSession()); return node
    }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { layout.flexDirection = .column; layout.alignItems = .stretch }
    func _updateNode(_ node: Node) {
        let session = node.firstResource(SpringDragSession.self)!
        session.configure(offset: offset, target: target, spring: spring, enabled: isEnabled, reduced: node.prefersReducedMotion)
        let route = InputHandlerRoute(role: .drag, priority: .chrome, debugName: "spring-drag")
        InteractionRegistryHolder.current?.setPointer(node, route: route) { [weak session] event, phase, _ in
            guard isEnabled, event.button == .left, let session else { return .ignored }
            if phase == .down { session.begin(at: CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) }
            else { session.release() }
            return .handled
        }
        InteractionRegistryHolder.current?.setMotion(node, route: route) { [weak session] event, _ in
            guard let session, session.isDragging else { return .ignored }
            session.move(to: CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))); return .handled
        }
    }
    var _children: [any View] { [content] }
}

/// All gesture, velocity and scheduler state is owned by the mounted surface.
final class SpringDragSession: NodeResource, AnyAnimationController {
    private weak var node: Node?
    private weak var scheduler: AnimatorScheduler?
    private var binding: Binding<CGPoint>?
    private var spring = SpringSolution(response: 0.4, dampingFraction: 0.82)
    private var target = CGPoint.zero
    private var current = CGPoint.zero
    private var origin = CGPoint.zero
    private var press = CGPoint.zero
    private var start = CGPoint.zero
    private var releasePoint = CGPoint.zero
    private var velocity = CGPoint.zero
    private var trackers = (x: ScrollVelocityTracker(), y: ScrollVelocityTracker())
    private var elapsed = 0.0
    private var reduced = false
    private(set) var isDragging = false
    private(set) var isFinished = true
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    func mount(node: Node) {
        self.node = node; scheduler = AnimatorScheduler.current
        node.layoutDidUpdate = { [weak self] node in self?.origin = node.frame.origin; self?.place() }
    }
    func unmount(node: Node) { cancel(); binding = nil; self.node = nil }
    func configure(offset: Binding<CGPoint>, target: CGPoint, spring: SpringSolution, enabled: Bool, reduced: Bool) {
        binding = offset; self.target = target; self.spring = spring; self.reduced = reduced
        if isFinished && !isDragging { current = offset.wrappedValue }
        if !enabled { finishImmediately() }
        else if reduced && !isFinished { finishImmediately() }
        place()
    }
    private func local(_ point: CGPoint) -> CGPoint { node?.parent?.convertFromWindow(point) ?? point }
    func begin(at point: CGPoint) {
        cancel(); isDragging = true; press = local(point); start = current
        trackers.x.reset(); trackers.y.reset(); sample()
        if let node { PointerCaptureHolder.current?.acquire(node) }
    }
    func move(to point: CGPoint) {
        guard isDragging else { return }
        let point = local(point)
        current = CGPoint(x: start.x + point.x - press.x, y: start.y + point.y - press.y)
        sample(); publish()
    }
    private func sample() {
        let time = now()
        trackers.x.add(time: time, value: Float(current.x)); trackers.y.add(time: time, value: Float(current.y))
    }
    func release() {
        guard isDragging else { return }
        isDragging = false; PointerCaptureHolder.current?.release()
        velocity = CGPoint(x: CGFloat(trackers.x.velocity(at: now(), staleAfter: 0.12)),
                           y: CGFloat(trackers.y.velocity(at: now(), staleAfter: 0.12)))
        releasePoint = current; elapsed = 0
        if reduced { finishImmediately() }
        else { isFinished = false; scheduler?.register(self) }
    }
    func tick(deltaTime: Double) {
        guard !isFinished, deltaTime.isFinite, deltaTime >= 0 else { return }
        elapsed += deltaTime
        if elapsed >= spring.settlingDuration { finishImmediately(); return }
        let t = Float(elapsed)
        current = CGPoint(x: CGFloat(spring.position(at: t, from: Float(releasePoint.x), velocity: Float(velocity.x), to: Float(target.x))),
                          y: CGFloat(spring.position(at: t, from: Float(releasePoint.y), velocity: Float(velocity.y), to: Float(target.y))))
        publish()
    }
    func finishImmediately() {
        let changed = current != target || binding?.wrappedValue != target
        current = target; cancel()
        if changed { publish() } else { place() }
    }
    func cancel() {
        isFinished = true; scheduler?.unregister(self)
        if isDragging { isDragging = false; PointerCaptureHolder.current?.release() }
    }
    private func publish() { binding?.wrappedValue = current; place() }
    private func place() {
        guard let node else { return }
        node.frame.origin = CGPoint(x: origin.x + current.x, y: origin.y + current.y)
    }
}
