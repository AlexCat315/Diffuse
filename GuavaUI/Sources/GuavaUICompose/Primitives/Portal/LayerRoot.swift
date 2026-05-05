import GuavaUIRuntime

public struct LayerRoot<Content: View, Portals: View>: _PrimitiveView {
    private let content: Content
    private let portals: Portals

    public init(@ViewBuilder content: () -> Content,
                @ViewBuilder portals: () -> Portals) {
        self.content = content()
        self.portals = portals()
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "layer-root"
        return node
    }

    public func _updateNode(_ node: Node) {}

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.flexGrow = 1
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.flexGrow = 1
    }

    public var _children: [any View] {
        [
            content,
            _PortalLayer {
                portals
            }
        ]
    }
}

public extension LayerRoot where Portals == PortalHost {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content) {
            PortalHost()
        }
    }
}

private struct _PortalLayer<Content: View>: _PrimitiveView {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-layer"
        return node
    }

    func _updateNode(_ node: Node) {}

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.positionType = .absolute
        layout.setPosition(0, edge: .left)
        layout.setPosition(0, edge: .top)
        layout.setPosition(0, edge: .right)
        layout.setPosition(0, edge: .bottom)
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.positionType = .absolute
        layout.setPosition(0, edge: .left)
        layout.setPosition(0, edge: .top)
        layout.setPosition(0, edge: .right)
        layout.setPosition(0, edge: .bottom)
    }

    var _children: [any View] { [content] }
}

