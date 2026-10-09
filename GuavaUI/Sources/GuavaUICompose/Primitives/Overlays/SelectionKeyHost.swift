import GuavaUIRuntime

/// A local keyboard boundary shared by collection controls. Child inputs get first refusal.
struct SelectionKeyHost<Content: View>: _PrimitiveView {
    let onKey: (KeyEvent) -> Bool
    let content: Content
    init(onKey: @escaping (KeyEvent) -> Bool, @ViewBuilder content: () -> Content) {
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
        InteractionRegistryHolder.current?.setKey(node) { event, phase in
            guard phase != .capture else { return .ignored }
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
