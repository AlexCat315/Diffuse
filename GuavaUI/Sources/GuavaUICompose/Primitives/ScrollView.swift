import CoreGraphics
import GuavaUIRuntime

/// Clipping container that scrolls its content via mouse wheel input.
///
/// v1 limitations:
/// - Content is laid out within the ScrollView's box. To enable real overflow
///   the inner content must use explicit sizes that exceed the ScrollView's
///   frame; flex-grown children will be compressed by Yoga.
/// - Wheel routing requires the cursor to be over the ScrollView (handled by
///   `EventDispatcher`'s wheel hit-test).
public struct ScrollView<Content: View>: _PrimitiveView {
    public enum Axis: Sendable { case vertical, horizontal, both }

    public let axes: Axis
    public let content: Content

    /// Pixels scrolled per wheel notch. SDL3 reports wheel deltas in lines.
    public var wheelStep: Float = 30

    public init(_ axes: Axis = .vertical,
                @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.clipsToBounds = true
        return n
    }

    public func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let axes = self.axes
        let step = self.wheelStep
        registry.setWheel(node) { event, _ in
            // Wheel up (positive Y) scrolls content up — i.e. offset.y decreases.
            let dx: Float = (axes == .horizontal || axes == .both) ? -event.x * step : 0
            let dy: Float = (axes == .vertical   || axes == .both) ? -event.y * step : 0
            if dx == 0 && dy == 0 { return .ignored }

            var offset = node.contentOffset
            offset.x += CGFloat(dx)
            offset.y += CGFloat(dy)

            // Clamp to [0, max(0, contentSize - viewSize)] using the immediate
            // child's frame as content size. With multiple children we'd union.
            let viewSize = node.frame.size
            if let child = node.children.first {
                let contentSize = child.frame.size
                offset.x = max(0, min(offset.x, max(0, contentSize.width  - viewSize.width)))
                offset.y = max(0, min(offset.y, max(0, contentSize.height - viewSize.height)))
            } else {
                offset = .zero
            }
            node.contentOffset = offset
            return .handled
        }
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.overflow = .hidden
    }

    public var _children: [any View] { [content] }
}
