internal import GuavaUIRuntime

private let columnIdentityKey = "GuavaUI.table.column"

struct TableColumnIdentity: ViewModifier {
    let id: String
    func apply(node: Node) { node.attachments[columnIdentityKey] = id }
}

/// Handoff before reconciliation removes a focused header or embedded control.
/// Cell windows may unmount, but focus must not remain on a hidden column.
struct TableColumnsHost<Content: View>: _PrimitiveView {
    let visibleIDs: Set<String>
    @ViewBuilder let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        func hiddenColumn(containing target: Node?) -> Bool {
            guard let target, FocusChainHolder.current?.contains(target, in: node) == true else { return false }
            var ancestor = target
            while ancestor !== node {
                let current = ancestor
                if let id = current.attachments[columnIdentityKey] as? String { return !visibleIDs.contains(id) }
                guard let parent = current.parent else { return false }
                ancestor = parent
            }
            return false
        }
        if hiddenColumn(containing: PointerCaptureHolder.current?.target) { PointerCaptureHolder.current?.release() }
        if hiddenColumn(containing: FocusChainHolder.current?.focused) {
            var pending = [node]
            while let candidate = pending.popLast() {
                if candidate.isFocusable && candidate.accessibility?.label == "Column visibility" {
                    FocusChainHolder.current?.focus(candidate, visible: FocusChainHolder.current?.isFocusVisible ?? true)
                    break
                }
                pending.append(contentsOf: candidate.children.reversed())
            }
        }
    }
    var _children: [any View] { [content] }
}
