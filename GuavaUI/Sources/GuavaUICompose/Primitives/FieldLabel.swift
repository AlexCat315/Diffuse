import GuavaUIRuntime

public struct FieldLabelOptions {
    public var isRequired = false
    public var help = ""
    /// Matches an input's accessibility identifier within this scene, never another window.
    public var targetID: String?
    public init() {}
}
public struct FieldLabel: View {
    public let title: String
    public var options = FieldLabelOptions()
    public init(_ title: String, configure: (inout FieldLabelOptions) -> Void = { _ in }) { self.title = title; configure(&options) }
    public var body: some View { FieldLabelHost(title: title, options: options) }
}
private struct FieldLabelHost: _PrimitiveView {
    let title: String
    let options: FieldLabelOptions
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {}
    func _children(for node: Node) -> [any View] {
        let text = Text(title + (options.isRequired ? " *" : "")).font(.label).foregroundColor(.onSurface)
        guard let targetID = options.targetID else { return [AnyView(text)] }
        return [AnyView(Button(action: { [weak node] in
            guard let node else { return }
            var root = node; while let parent = root.parent { root = parent }
            func find(_ candidate: Node) -> Node? {
                if candidate.isFocusable && candidate.accessibility?.identifier == targetID { return candidate }
                return candidate.children.lazy.compactMap(find).first
            }
            if let target = find(root) { FocusChainHolder.current?.focus(target) }
        }) { text }.buttonStyle(FieldLabelStyle()).accessibility { $0.label = title; $0.help = options.help })]
    }
}
private struct FieldLabelStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        AnyView(c.label).border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 1 : 0)
    }
}
