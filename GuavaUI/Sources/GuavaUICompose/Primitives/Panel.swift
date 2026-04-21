import GuavaUIRuntime

/// Surface container with a labelled header bar. Visual chrome is delegated
/// to the active `PanelStyle` (defaults to `DefaultPanelStyle`); call sites
/// only supply title, optional accessory, and content.
public struct Panel<Accessory: View, Content: View>: View {
    public let title: String
    public let isActive: Bool
    public let accessory: Accessory
    public let content: Content

    public init(_ title: String,
                isActive: Bool = false,
                @ViewBuilder accessory: () -> Accessory,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.isActive = isActive
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        PanelHost(title: title,
                  isActive: isActive,
                  accessory: AnyView(accessory),
                  content: AnyView(content))
    }
}

public extension Panel where Accessory == EmptyView {
    init(_ title: String,
         isActive: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(title, isActive: isActive,
                  accessory: { EmptyView() },
                  content: content)
    }
}

// MARK: - PanelHost

struct PanelHost: _PrimitiveView {
    let title: String
    let isActive: Bool
    let accessory: AnyView
    let content: AnyView

    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) {}
    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        return l
    }

    func _children(for node: Node) -> [any View] {
        let style = node.compositionValue(of: PanelStyleEnvironment.key)
        let cfg = PanelStyleConfiguration(
            title: title,
            accessory: accessory,
            content: content,
            isActive: isActive,
            theme: node.theme
        )
        return [style.makeBody(cfg)]
    }
}
