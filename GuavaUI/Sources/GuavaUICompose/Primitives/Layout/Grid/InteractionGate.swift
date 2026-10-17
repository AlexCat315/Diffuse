internal import GuavaUIRuntime

struct GridInteractionHost<Content: View>: _PrimitiveView {
    let isEnabled: Bool
    @ViewBuilder let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.allowsHitTesting = isEnabled
        guard !isEnabled, let chain = FocusChainHolder.current else { return }
        if let target = PointerCaptureHolder.current?.target, chain.contains(target, in: node) { PointerCaptureHolder.current?.release() }
        if let target = chain.focused, chain.contains(target, in: node) { chain.clear() }
    }
    var _children: [any View] { [content] }
}
