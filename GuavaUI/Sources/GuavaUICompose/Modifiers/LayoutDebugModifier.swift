import GuavaUIRuntime

public enum LayoutDebugAttachmentKey {
    public static let layoutRole = "GuavaUI.layout.role"
    public static let semanticRole = "GuavaUI.semantic.role"
    public static let debugName = "GuavaUI.debug.name"
}

public struct LayoutDebugModifier: ViewModifier {
    let layoutRole: String?
    let semanticRole: String?
    let debugName: String?

    public init(layoutRole: String? = nil,
                semanticRole: String? = nil,
                debugName: String? = nil) {
        self.layoutRole = layoutRole
        self.semanticRole = semanticRole
        self.debugName = debugName
    }

    public func apply(node: Node) {
        if let layoutRole {
            node.attachments[LayoutDebugAttachmentKey.layoutRole] = layoutRole
        }
        if let semanticRole {
            node.attachments[LayoutDebugAttachmentKey.semanticRole] = semanticRole
        }
        if let debugName {
            node.attachments[LayoutDebugAttachmentKey.debugName] = debugName
        }
    }
}

public extension View {
    func layoutRole(_ value: String) -> some View {
        modifier(LayoutDebugModifier(layoutRole: value))
    }

    func semanticRole(_ value: String) -> some View {
        modifier(LayoutDebugModifier(semanticRole: value))
    }

    func debugName(_ value: String) -> some View {
        modifier(LayoutDebugModifier(debugName: value))
    }
}

