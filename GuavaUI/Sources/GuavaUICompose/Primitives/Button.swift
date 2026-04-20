import GuavaUIRuntime

/// Tappable container. Wraps a label view and fires `action` on a click that
/// completes (down + up) over the same node. No visual press state in v1 —
/// callers add `.background(...)` per state via their own model.
public struct Button<Label: View>: _PrimitiveView {
    public let action: () -> Void
    public let label: Label

    public init(action: @escaping () -> Void,
                @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    public func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let action = self.action
        // Pressed flag is captured per-node; persists across handler invocations.
        var pressed = false
        registry.setPointer(node) { _, pointerPhase, _ in
            switch pointerPhase {
            case .down:
                pressed = true
                return .handled
            case .up:
                if pressed {
                    pressed = false
                    action()
                    return .handled
                }
                return .ignored
            }
        }
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        // Default to row so single-text labels lay out left-to-right.
        layout.flexDirection = .row
        layout.alignItems = .center
        layout.justifyContent = .center
    }

    public var _children: [any View] { [label] }
}
