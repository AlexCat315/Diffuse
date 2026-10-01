import GuavaUIRuntime

/// Traps keyboard focus and shortcuts in a modal subtree. Nested scopes restore
/// the prior focus and its keyboard/pointer modality when they are removed.
public struct FocusScope<Content: View>: _PrimitiveView {
    private let content: Content
    private let restoresCommands: Bool
    public init(restoresCommands: Bool = false, @ViewBuilder content: () -> Content) { self.restoresCommands = restoresCommands; self.content = content() }
    public func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false; node.isFocusable = true
        node.addResource(ModalFocusResource()); return node
    }
    public func _updateNode(_ node: Node) {
        let chain = FocusChainHolder.current
        node.firstResource(ModalFocusResource.self)?.bind(node, chain: chain, restoresCommands: restoresCommands)
        node.layoutDidUpdate = { [weak chain] node in chain?.settleScope(node) }
    }
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public var _children: [any View] { [content] }
}
