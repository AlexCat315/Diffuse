import GuavaUIRuntime

final class ToolbarOverflowFocus {
    var pendingVisibility: Bool?
}

/// Keep command nodes measured and mounted while their menu representation is
/// active. Hidden commands receive neither input nor accessibility traversal.
struct ToolbarRetainedCommand<Content: View>: _PrimitiveView {
    let isVisible: Bool
    let focus: ToolbarOverflowFocus
    var isOverflow = false
    @ViewBuilder let content: Content

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateNode(_ node: Node) {
        node.isInteractionEnabled = isVisible
        node.opacity = isVisible ? 1 : 0
        node.accessibility = AccessibilitySemantics(.group) { $0.isHidden = !isVisible }
        if !isVisible {
            if let focused = FocusChainHolder.current?.focused,
               FocusChainHolder.current?.contains(focused, in: node) == true {
                focus.pendingVisibility = FocusChainHolder.current?.isFocusVisible ?? true
                FocusChainHolder.current?.clear()
            }
            if let captured = PointerCaptureHolder.current?.target,
               FocusChainHolder.current?.contains(captured, in: node) == true {
                PointerCaptureHolder.current?.release()
            }
        }
        node.layoutDidUpdate = { node in
            guard isOverflow, let visible = focus.pendingVisibility else { return }
            func button(in node: Node) -> Node? {
                guard node.acceptsSubtreeInput else { return nil }
                if node.isFocusable && node.isTabStop { return node }
                return node.children.lazy.compactMap { button(in: $0) }.first
            }
            var owner = node
            if !isVisible {
                while owner.accessibility?.role != .toolbar, let parent = owner.parent { owner = parent }
            }
            if let target = button(in: owner) {
                FocusChainHolder.current?.focus(target, visible: visible)
                ScrollReveal.reveal(target)
                focus.pendingVisibility = nil
            }
        }
    }
    var _children: [any View] { [content] }
}
