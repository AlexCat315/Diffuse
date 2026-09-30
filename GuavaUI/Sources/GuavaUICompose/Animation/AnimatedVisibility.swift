import GuavaUIRuntime

/// Retains content through its exit animation, then unmounts it. Unlike a
/// conditional `if`, both insertion and removal can animate. Rapid reversal
/// continues from the currently displayed value, preserving child state.
public struct AnimatedVisibility<Content: View>: View {
    public let isVisible: Bool
    public let collapses: Bool
    public let animation: Animation?
    private let content: Content
    @State private var completionRevision = 0

    public init(isVisible: Bool, collapses: Bool = true,
                animation: Animation? = nil, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.collapses = collapses
        self.animation = animation
        self.content = content()
    }

    public var body: some View {
        _VisibilityHost(isVisible: isVisible, collapses: collapses,
                        animation: animation, revision: completionRevision,
                        content: content, onFinished: { completionRevision &+= 1 })
    }
}

private final class VisibilityState: NodeResource {
    var progress: Float = 0
    var target: Bool?
    var expandedHeight: Float = 0
    var controller: AnimationController<Float>?
    var onFinished: () -> Void = {}

    func mount(node: Node) {}
    func unmount(node: Node) { controller?.cancel(); onFinished = {} }
}

private struct _VisibilityHost<Content: View>: _PrimitiveView {
    let isVisible: Bool
    let collapses: Bool
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
        node.allowsHitTesting = isVisible
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
            if let child = node.children.first {
                let height = Float(child.frame.height)
                state.expandedHeight = state.progress >= 1 ? height : max(state.expandedHeight, height)
            }
            Self.apply(state, to: node, collapses: collapses)
        }
        guard state.target != isVisible else { return }
        let wasMounted = state.target != nil
        state.target = isVisible
        state.controller?.cancel()
        let target: Float = isVisible ? 1 : 0
        if !wasMounted {
            state.progress = target
            Self.apply(state, to: node, collapses: collapses)
            return
        }
        let controller = AnimationController(from: state.progress, to: target,
                                              animation: animation ?? .semantic(.medium, in: node.theme)) {
            [weak state, weak node] progress in
            guard let state, let node else { return }
            state.progress = progress
            Self.apply(state, to: node, collapses: collapses)
            if progress == target { state.onFinished() }
        }
        state.controller = controller
        AnimatorScheduler.current.register(controller)
        Self.apply(state, to: node, collapses: collapses)
    }

    private static func apply(_ state: VisibilityState, to node: Node, collapses: Bool) {
        node.opacity = max(0, min(1, state.progress))
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
        return isVisible || (state?.progress ?? 0) > 0 ? [content] : []
    }
}
