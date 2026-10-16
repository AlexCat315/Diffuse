private import GuavaUIRuntime

struct AppBarBack: _PrimitiveView {
    let command: MenuItem
    let isEnabled: Bool
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {}
    func _children(for node: Node) -> [any View] {
        var ancestor: Node? = node
        var direction = Direction.ltr
        while let current = ancestor {
            if let authored = current.layoutNode?.direction, authored != .inherit { direction = authored; break }
            ancestor = current.parent
        }
        return [Button(icon: .resource(direction == .rtl ? UIIcons.Navigation.arrowRight : UIIcons.Navigation.arrowLeft),
                       isEnabled: isEnabled && command.isEnabled, tooltip: command.title, action: command.action)
            .iconScaling(.fixed).frame(width: 44, minHeight: 44).accessibilityLabel(command.title)]
    }
}
