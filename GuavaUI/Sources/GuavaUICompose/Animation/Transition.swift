#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import GuavaUIRuntime

/// Reusable presentation effects. Composition adds offsets and combines fades;
/// each effect uses the same progress so interruption stays continuous.
public struct Transition: Equatable, Sendable {
    public var fades: Bool
    public var offset: CGPoint
    public init(fades: Bool = false, offset: CGPoint = .zero) {
        self.fades = fades
        self.offset = offset
    }
    public static let identity = Transition()
    public static let opacity = Transition(fades: true)
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> Transition {
        Transition(offset: CGPoint(x: x, y: y))
    }
    public func combined(with other: Transition) -> Transition {
        Transition(fades: fades || other.fades,
                   offset: CGPoint(x: offset.x + other.offset.x, y: offset.y + other.offset.y))
    }
}

/// Keeps content alive during its exit animation, then releases its resources.
/// Hidden/exiting content cannot receive pointer, keyboard or tab focus.
public struct TransitionView<Content: View>: View {
    let isVisible: Bool
    let insertion: Transition
    let removal: Transition
    let motion: SemanticMotionRef
    let content: Content
    @State private var retained: Bool

    public init(isVisible: Bool, transition: Transition = .opacity,
                removal: Transition? = nil, motion: SemanticMotionRef = .medium,
                @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.insertion = transition
        self.removal = removal ?? transition
        self.motion = motion
        self.content = content()
        _retained = State(wrappedValue: isVisible)
    }
    public var body: some View {
        _TransitionHost(isVisible: isVisible, insertion: insertion, removal: removal, motion: motion,
                        content: isVisible || retained ? AnyView(content) : nil,
                        onRetain: { if !retained { retained = true } },
                        onRemoved: { if retained { retained = false } })
    }
}

private struct _TransitionHost: _PrimitiveView {
    let isVisible: Bool
    let insertion: Transition
    let removal: Transition
    let motion: SemanticMotionRef
    let content: AnyView?
    let onRetain: () -> Void
    let onRemoved: () -> Void
    func _makeNode() -> Node {
        let node = Node()
        node.addResource(TransitionResource())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        return layout
    }
    func _updateNode(_ node: Node) {
        node.isInteractionEnabled = isVisible
        if isVisible { onRetain() }
        node.firstResource(TransitionResource.self)?.update(node: node, visible: isVisible,
            effect: isVisible ? insertion : removal, animation: motion.resolve(node.theme), onRemoved: onRemoved)
    }
    var _children: [any View] { content.map { [$0] } ?? [] }
}

private final class TransitionResource: NodeResource {
    var target: Bool?
    var controller: AnimationController<Float>?
    func mount(node: Node) {}
    func unmount(node: Node) { controller?.cancel(); controller = nil }
    func update(node: Node, visible: Bool, effect: Transition, animation: Animation, onRemoved: @escaping () -> Void) {
        guard target != visible else { return }
        let initial = target == nil
        target = visible
        controller?.cancel()
        if initial && !visible { return }
        if initial {
            node.subtreeOpacity = effect.fades ? 0 : 1
            node.contentOffset = CGPoint(x: -effect.offset.x, y: -effect.offset.y)
        }
        let startOpacity = node.subtreeOpacity
        let endOpacity: Float = visible || !effect.fades ? 1 : 0
        let startOffset = node.contentOffset
        let endOffset = visible ? CGPoint.zero : CGPoint(x: -effect.offset.x, y: -effect.offset.y)
        let apply: (Float) -> Void = { [weak self, weak node] value in
            guard self != nil, let node else { return }
            node.subtreeOpacity = startOpacity + (endOpacity - startOpacity) * value
            node.contentOffset = CGPoint(x: startOffset.x + (endOffset.x - startOffset.x) * CGFloat(value),
                                         y: startOffset.y + (endOffset.y - startOffset.y) * CGFloat(value))
            if !visible && value == 1 { onRemoved() }
        }
        let controller = AnimationController(from: Float(0), to: 1, animation: animation, apply: apply)
        self.controller = controller
        AnimatorScheduler.current.register(controller)
    }
}
