import GuavaUIRuntime

enum FormLabelScopeMarker { static let key = "GuavaUI.form.label-scope" }

/// A field ID is local to its form. Identical field names in another form
/// must not steal focus when this form's associated label is activated.
struct FormLabelScope<Content: View>: _PrimitiveView {
    @ViewBuilder let content: Content
    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) { node.attachments[FormLabelScopeMarker.key] = true }
    var _children: [any View] { [content] }
}
