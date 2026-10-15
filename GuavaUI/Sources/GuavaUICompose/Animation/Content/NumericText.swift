import Foundation
import GuavaUIRuntime

/// A formatted number with value interpolation. Assistive clients receive the
/// final value immediately; intermediate values are only a visual transition.
public struct NumericText: View {
    private let value: Double
    private let animation: Animation?
    private let format: (Double) -> String
    @State private var displayed: Double
    public init(_ value: Double, animation: Animation? = nil,
                format: @escaping (Double) -> String = { String(format: "%.0f", $0) }) {
        self.value = value.isFinite ? value : 0; self.animation = animation; self.format = format
        _displayed = State(wrappedValue: value.isFinite ? value : 0)
    }
    public var body: some View {
        NumberHost(value: value, animation: animation, label: format(value),
                   publish: { displayed = $0 }, content: Text(format(displayed)))
    }
}
private struct NumberHost: _PrimitiveView {
    let value: Double
    let animation: Animation?
    let label: String
    let publish: (Double) -> Void
    let content: Text
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; node.addResource(NumberSession()); return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { layout.flexDirection = .column; layout.alignItems = .stretch }
    func _updateNode(_ node: Node) {
        node.accessibility = AccessibilitySemantics(.staticText) { $0.label = label; $0.combinesChildren = true }
        node.firstResource(NumberSession.self)!.update(value: value,
            animation: animation ?? ActiveAnimationContext.current ?? .semantic(.medium, in: node.theme),
            reduced: node.prefersReducedMotion, publish: publish)
    }
    var _children: [any View] { [content] }
}
private final class NumberSession: NodeResource {
    private var target: Double?
    private var current = 0.0
    private var controller: AnimationController<Double>?
    private weak var scheduler: AnimatorScheduler?
    private var publish: (Double) -> Void = { _ in }
    func mount(node: Node) { scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { stop(); publish = { _ in } }
    private func stop() {
        if let controller { controller.cancel(); scheduler?.unregister(controller) }
        controller = nil
    }
    func update(value: Double, animation: Animation, reduced: Bool, publish: @escaping (Double) -> Void) {
        self.publish = publish
        if ActiveAnimationContext.disablesAnimations {
            let changed = target != value || current != value
            stop(); current = value; target = value
            if changed { publish(value) }
            return
        }
        if reduced {
            let changed = target != value || current != value || controller?.isFinished == false
            if target == value { controller?.finishImmediately() }
            stop(); current = value; target = value
            if changed { publish(value) }
            return
        }
        guard target != value else { return }
        let mounted = target != nil
        target = value; stop()
        guard mounted else { current = value; publish(value); return }
        let controller = AnimationController(from: current, to: value, animation: animation) { [weak self] value in
            self?.current = value; self?.publish(value)
        }
        self.controller = controller
        ActiveAnimationContext.currentCompletion?.attach(controller)
        scheduler?.register(controller)
    }
}
