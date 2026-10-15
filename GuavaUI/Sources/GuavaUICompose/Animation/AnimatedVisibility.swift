import Foundation
import GuavaUIRuntime

/// Retains content through its exit animation, then unmounts it. Unlike a
/// conditional `if`, both insertion and removal can animate. Rapid reversal
/// continues from the currently displayed value, preserving child state.
public struct AnimatedVisibility<Content: View>: View {
    public let isVisible: Bool
    public let transition: Transition
    public let animateOnMount: Bool
    public let animation: Animation?
    private let content: Content
    private let onVisibilitySettled: ((Bool) -> Void)?
    @State private var completionRevision = 0

    public init(isVisible: Bool, collapses: Bool = true,
                animation: Animation? = nil, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.transition = collapses ? .opacity.combined(with: .collapse) : .opacity
        self.animateOnMount = false
        self.onVisibilitySettled = nil
        self.animation = animation
        self.content = content()
    }

    public init(isVisible: Bool, transition: Transition, animation: Animation? = nil,
                animateOnMount: Bool = false, onVisibilitySettled: ((Bool) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible; self.transition = transition; self.animation = animation
        self.animateOnMount = animateOnMount; self.content = content()
        self.onVisibilitySettled = onVisibilitySettled
    }

    public var body: some View {
        _VisibilityHost(isVisible: isVisible, transition: transition, animateOnMount: animateOnMount,
                        animation: animation, revision: completionRevision,
                        content: content, onFinished: { completionRevision &+= 1; onVisibilitySettled?(isVisible) })
    }
}

private final class VisibilityState: NodeResource {
    var progress: Float = 0
    var visual = Transition.Effect()
    var target: Bool?
    var expandedHeight: Float = 0
    var controller: AnimationController<Float>?
    var onFinished: () -> Void = {}
    private weak var scheduler: AnimatorScheduler?

    func mount(node: Node) { scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { cancel(); onFinished = {}; scheduler = nil }
    func cancel() {
        guard let controller else { return }
        controller.cancel(); scheduler?.unregister(controller); self.controller = nil
    }
    func animate(_ controller: AnimationController<Float>) {
        self.controller = controller
        if !controller.isFinished { scheduler?.register(controller) }
    }
    func settleImmediately() {
        guard let controller, !controller.isFinished else { return }
        controller.finishImmediately(); scheduler?.unregister(controller); self.controller = nil
    }
}

private struct _VisibilityHost<Content: View>: _PrimitiveView {
    let isVisible: Bool
    let transition: Transition
    let animateOnMount: Bool
    private var collapses: Bool { transition.insertion.collapse || transition.removal.collapse }
    let animation: Animation?
    let revision: Int
    let content: Content
    let onFinished: () -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.clipsToBounds = collapses
        node.addResource(VisibilityState())
        return node
    }

    func _updateNode(_ node: Node) {
        guard let state = node.firstResource(VisibilityState.self) else { return }
        state.onFinished = onFinished
        node.clipsToBounds = collapses
        node.allowsHitTesting = isVisible
        node.isInteractionEnabled = isVisible
        if !isVisible {
            if let focused = FocusChainHolder.current?.focused, !focused.acceptsSubtreeInput {
                FocusChainHolder.current?.clear()
            }
            if let captured = PointerCaptureHolder.current?.target, !captured.acceptsSubtreeInput {
                PointerCaptureHolder.current?.release()
            }
        }
        node.layoutDidUpdate = { [weak state] node in
            guard let state else { return }
            if let child = node.layoutNode?.children.first {
                let height = Float(child.frame.height)
                state.expandedHeight = height
            }
            Self.apply(state, to: node, collapses: collapses)
        }
        if state.target == isVisible {
            if node.prefersReducedMotion { state.settleImmediately() }
            return
        }
        let wasMounted = state.target != nil
        state.target = isVisible
        state.cancel()
        let target: Float = isVisible ? 1 : 0
        let goal = isVisible ? Transition.Effect() : transition.removal
        if node.prefersReducedMotion {
            state.progress = target; state.visual = goal
            Self.apply(state, to: node, collapses: collapses)
            if wasMounted || (animateOnMount && isVisible) { state.onFinished() }
            return
        }
        if !wasMounted {
            state.progress = isVisible && animateOnMount ? 0 : target
            state.visual = isVisible && animateOnMount ? transition.insertion : goal
            if !animateOnMount || !isVisible {
                Self.apply(state, to: node, collapses: collapses)
                return
            }
        }
        if isVisible, state.progress == 0 { state.visual = transition.insertion }
        let from = state.visual
        let fromProgress = state.progress
        let controller = AnimationController(from: Float(0), to: Float(1),
                                              animation: animation ?? .semantic(.medium, in: node.theme)) {
            [weak state, weak node] amount in
            guard let state, let node else { return }
            state.progress = fromProgress + (target - fromProgress) * amount
            state.visual = from.interpolating(to: goal, amount)
            Self.apply(state, to: node, collapses: collapses)
            if amount == 1 { state.onFinished() }
        }
        state.animate(controller)
        Self.apply(state, to: node, collapses: collapses)
    }

    private static func apply(_ state: VisibilityState, to node: Node, collapses: Bool) {
        node.opacity = max(0, min(1, state.visual.opacity))
        // contentOffset participates in both rendering and hit testing, keeping
        // pointer coordinates aligned throughout a moving transition.
        node.contentOffset = CGPoint(x: CGFloat(-state.visual.x), y: CGFloat(-state.visual.y))
        // Likewise for scale: the node, the geometry it reports and the
        // rectangle the pointer lands in all move together, so a panel that is
        // still growing is clickable exactly where it is drawn. Settling at
        // `Effect()` hands back `identity`, so this resets itself.
        node.transform = state.visual.scale
        if collapses {
            node.layoutNode?.maxHeight = state.progress >= 1 ? nil
                : (state.expandedHeight > 0 ? state.expandedHeight * max(0, state.progress) : nil)
            if state.target == false, state.progress == 0 { node.layoutNode?.maxHeight = 0 }
        }
    }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.minHeight = 0
    }

    func _children(for node: Node) -> [any View] {
        _ = revision
        let state = node.firstResource(VisibilityState.self)
        // Measure the full content while the host clips its animated height.
        // Shrinking the child to that height feeds a smaller measurement back
        // into the next animation frame and causes a reveal to stall.
        guard isVisible || (state?.progress ?? 0) > 0 else { return [] }
        if collapses {
            return [Box(direction: .column, alignItems: .stretch) { content }.flex(0, shrink: 0)]
        }
        // Translation/opacity transitions keep the child's flex contract.
        // Full-window modal content must still fill its assigned viewport.
        return [content]
    }
}
