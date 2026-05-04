import GuavaUIRuntime

/// Renders `PopoverOverlayRegistry` entries at root level so popover content
/// is never clipped by ancestor containers. Place at the end of the root view.
public struct OverlayHost: View {
    public init() {}

    public var body: some View {
        _OverlayHostPrimitive()
    }
}

private struct _OverlayHostPrimitive: _PrimitiveView {
    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {}

    func _makeLayoutNode() -> LayoutNode? { nil }

    func _updateLayout(_ layout: LayoutNode) {}

    var _children: [any View] {
        PopoverOverlayRegistry.entries.map { entry in
            _OverlayEntrySlot(entry: entry)
                .id(entry.id)
        }
    }
}

private struct _OverlayEntrySlot: _PrimitiveView {
    let entry: PopoverOverlayEntry

    func _makeNode() -> Node {
        Node()
    }

    func _updateNode(_ node: Node) {}

    func _makeLayoutNode() -> LayoutNode? {
        let ln = LayoutNode()
        ln.positionType = .absolute
        ln.setPosition(Float(entry.position.x), edge: .left)
        ln.setPosition(Float(entry.position.y), edge: .top)
        if let width = entry.width {
            ln.width = width
        }
        return ln
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.setPosition(Float(entry.position.x), edge: .left)
        layout.setPosition(Float(entry.position.y), edge: .top)
    }

    var _children: [any View] {
        [entry.content]
    }
}
