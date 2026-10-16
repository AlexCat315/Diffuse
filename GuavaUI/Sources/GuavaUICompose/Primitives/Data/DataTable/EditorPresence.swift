internal import GuavaUIRuntime

/// A cell window may move between frozen and scrolling panes. Its detached
/// editor must not interpret that reconciliation as a user committing a draft.
struct DataTableEditorPresence<Content: View>: _PrimitiveView {
    let focus: DataTableFocusTarget
    let content: (@escaping () -> Bool) -> Content
    init(focus: DataTableFocusTarget, @ViewBuilder content: @escaping (@escaping () -> Bool) -> Content) {
        self.focus = focus; self.content = content
    }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {}
    func _children(for node: Node) -> [any View] {
        [content { [weak node, weak focus] in
            guard let node, let root = focus?.node else { return false }
            return FocusChainHolder.current?.contains(node, in: root) == true
        }]
    }
}
