import GuavaUIRuntime

public struct PortalHost: View {
    public init() {}

    public var body: some View {
        _PortalHostPrimitive()
    }
}

private struct _PortalHostPrimitive: _PrimitiveView {
    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-host"
        return node
    }

    func _updateNode(_ node: Node) {}

    func _makeLayoutNode() -> LayoutNode? { nil }

    func _updateLayout(_ layout: LayoutNode) {}

    var _children: [any View] {
        PortalRegistry.entries.map { entry in
            _PortalEntrySlot(entry: entry)
                .id(entry.id)
        }
    }
}

private struct _PortalEntrySlot: _PrimitiveView {
    let entry: PortalEntry

    func _makeNode() -> Node {
        let node = Node()
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-entry"
        node.attachments[LayoutDebugAttachmentKey.debugName] = entry.id
        return node
    }

    func _updateNode(_ node: Node) {}

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.positionType = .absolute
        layout.setPosition(Float(entry.position.x), edge: .left)
        layout.setPosition(Float(entry.position.y), edge: .top)
        if let width = entry.width {
            layout.width = width
        }
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.positionType = .absolute
        layout.setPosition(Float(entry.position.x), edge: .left)
        layout.setPosition(Float(entry.position.y), edge: .top)
        layout.width = entry.width
    }

    var _children: [any View] {
        [entry.content]
    }
}

