import GuavaUIRuntime

/// A local keyboard boundary shared by collection controls. Child inputs get first refusal.
struct SelectionKeyHost<Content: View>: _PrimitiveView {
    let isEnabled: Bool
    let onKey: (KeyEvent) -> Bool
    let content: Content
    init(isEnabled: Bool = true, onKey: @escaping (KeyEvent) -> Bool, @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.onKey = onKey
        self.content = content()
    }
    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.isFocusable = true
        return node
    }
    func _updateNode(_ node: Node) {
        node.isFocusable = isEnabled
        node.allowsHitTesting = isEnabled
        if !isEnabled {
            if let captured = PointerCaptureHolder.current?.target,
               FocusChainHolder.current?.contains(captured, in: node) == true { PointerCaptureHolder.current?.release() }
            if let focused = FocusChainHolder.current?.focused,
               FocusChainHolder.current?.contains(focused, in: node) == true { FocusChainHolder.current?.clear() }
        }
        InteractionRegistryHolder.current?.setKey(node) { event, phase in
            guard isEnabled, phase != .capture else { return .ignored }
            return onKey(event) ? .handled : .ignored
        }
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.flexGrow = 1
        layout.flexShrink = 1
        return layout
    }
    var _children: [any View] { [content] }
}
