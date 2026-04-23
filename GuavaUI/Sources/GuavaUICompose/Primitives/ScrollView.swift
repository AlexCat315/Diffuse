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
    public let consumePolicy: ScrollConsumePolicy

    public init(_ axes: Axis = .vertical,
                consumePolicy: ScrollConsumePolicy = .whenOffsetChanged,
                @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.consumePolicy = consumePolicy
        self.content = content()
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.clipsToBounds = true
        return n
    }

    public func _updateNode(_ node: Node) {
        let theme = node.theme
        let axes = self.axes
        let step = self.wheelStep
        let consumePolicy = self.consumePolicy
        let trackThickness: Float = 8
        let trackInset: Float = 2

        if let registry = InteractionRegistryHolder.current {
            registry.setWheel(node) { event, _ in
                // Wheel up (positive Y) scrolls content up — i.e. offset.y decreases.
                let dx: Float = (axes == .horizontal || axes == .both) ? -event.x * step : 0
                let dy: Float = (axes == .vertical   || axes == .both) ? -event.y * step : 0
                if dx == 0 && dy == 0 { return .ignored }

                let previousOffset = node.contentOffset
                var nextOffset = previousOffset
                nextOffset.x += CGFloat(dx)
                nextOffset.y += CGFloat(dy)

                // Clamp to [0, max(0, contentSize - viewSize)] using the immediate
                // child's frame as content size. With multiple children we'd union.
                let viewSize = node.frame.size
                if let child = node.children.first {
                    let contentSize = child.frame.size
                    nextOffset.x = max(0, min(nextOffset.x, max(0, contentSize.width  - viewSize.width)))
                    nextOffset.y = max(0, min(nextOffset.y, max(0, contentSize.height - viewSize.height)))
                } else {
                    nextOffset = .zero
                }
                node.contentOffset = nextOffset
                return consumePolicy.result(didScroll: nextOffset != previousOffset)
            }
        }

        // Scrollbar painter — runs after children render. We can't draw after
        // children with the current `Node.draw` ordering (it runs before
        // children), so we paint the bar onto the ScrollView's own background
        // pass. To keep it visible above scrolled content, we add a sibling
        // overlay node on first update.
        let trackColor = theme.colors.surfaceVariant
        let thumbColor = theme.colors.onSurfaceMuted
        node.overlayDraw = { [weak node] list, origin in
            guard let node else { return }
            let viewW = Float(node.frame.size.width)
            let viewH = Float(node.frame.size.height)
            guard let content = node.children.first else { return }
            let contentW = Float(content.frame.size.width)
            let contentH = Float(content.frame.size.height)
            let offX = Float(node.contentOffset.x)
            let offY = Float(node.contentOffset.y)

            // Vertical bar.
            if (axes == .vertical || axes == .both), contentH > viewH, viewH > 0 {
                let trackX = Float(origin.x) + viewW - trackThickness - trackInset
                let trackY = Float(origin.y) + trackInset
                let trackH = viewH - 2 * trackInset
                list.addRoundedRect(
                    UIRect(x: trackX, y: trackY,
                           width: trackThickness, height: trackH),
                    radius: trackThickness / 2,
                    color: trackColor
                )
                let thumbH = max(trackThickness * 2, trackH * (viewH / contentH))
                let maxOff = contentH - viewH
                let t = maxOff > 0 ? offY / maxOff : 0
                let thumbY = trackY + (trackH - thumbH) * t
                list.addRoundedRect(
                    UIRect(x: trackX, y: thumbY,
                           width: trackThickness, height: thumbH),
                    radius: trackThickness / 2,
                    color: thumbColor
                )
            }

            // Horizontal bar.
            if (axes == .horizontal || axes == .both), contentW > viewW, viewW > 0 {
                let trackY = Float(origin.y) + viewH - trackThickness - trackInset
                let trackX = Float(origin.x) + trackInset
                let trackW = viewW - 2 * trackInset
                list.addRoundedRect(
                    UIRect(x: trackX, y: trackY,
                           width: trackW, height: trackThickness),
                    radius: trackThickness / 2,
                    color: trackColor
                )
                let thumbW = max(trackThickness * 2, trackW * (viewW / contentW))
                let maxOff = contentW - viewW
                let t = maxOff > 0 ? offX / maxOff : 0
                let thumbX = trackX + (trackW - thumbW) * t
                list.addRoundedRect(
                    UIRect(x: thumbX, y: trackY,
                           width: thumbW, height: trackThickness),
                    radius: trackThickness / 2,
                    color: thumbColor
                )
            }
        }
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.overflow = .hidden
    }

    public var _children: [any View] { [content] }
}
