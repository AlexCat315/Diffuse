import GuavaUIRuntime

/// Indeterminate activity indicator.
///
/// The animation is registered with the owning node and cancelled when it
/// leaves the tree, so a spinner inside a conditionally-rendered branch never
/// keeps a clock running in the background. Reduced-motion is honoured by
/// freezing the glyph rather than hiding it — a static ring still communicates
/// "busy" without implying a percentage.
public struct Spinner: _PrimitiveView {
    public let size: Float
    public let isAnimating: Bool

    public init(size: Float = 16, isAnimating: Bool = true) {
        self.size = size.isFinite ? max(8, size) : 16
        self.isAnimating = isAnimating
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.addResource(LoadingAnimationClock())
        return node
    }

    public func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.width = size
        layout.height = size
    }

    public func _updateNode(_ node: Node) {
        let clock = node.firstResource(LoadingAnimationClock.self)!
        clock.configure(duration: 1, isActive: isAnimating && !node.prefersReducedMotion)
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            let phase = Float(clock.phase) * Float.pi * 2
            let cx = Float(origin.x + node.frame.width / 2), cy = Float(origin.y + node.frame.height / 2)
            let diameter = min(Float(node.frame.width), Float(node.frame.height))
            let thickness = max(1, diameter / 8)
            let radius = max(2, diameter / 2 - thickness)
            let color = (node.inheritedForegroundColor ?? node.theme.colors.onSurface).multipliedAlpha(node.opacity)
            // Tapered tail: each facet fades in turn so the ring reads as
            // rotating rather than as a dashed circle.
            for i in 0..<24 {
                let start = phase + Float(i) / 24 * Float.pi * 1.5
                let end = phase + Float(i + 1) / 24 * Float.pi * 1.5
                list.addLine(fromX: cx + cos(start) * radius, fromY: cy + sin(start) * radius,
                             toX: cx + cos(end) * radius, toY: cy + sin(end) * radius,
                             thickness: thickness, color: color.multipliedAlpha(Float(i + 1) / 24))
            }
        }
    }
}
