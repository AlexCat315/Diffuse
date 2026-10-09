import GuavaUIRuntime

public struct AccessibilityModifier: ViewModifier {
    public let configure: (inout AccessibilitySemantics) -> Void
    public func apply(node: Node) {
        // Layout/style wrappers around a single semantic control inherit that control's role.
        var targets: [Node] = []
        func collect(_ candidate: Node) {
            if let semantic = candidate.accessibility, semantic.role != .staticText && semantic.role != .group { targets.append(candidate); return }
            candidate.children.forEach(collect)
        }
        if node.accessibility == nil { node.children.forEach(collect) }
        var target = targets.count == 1 ? targets[0] : node
        var semantics = target.accessibility ?? AccessibilitySemantics(.group)
        configure(&semantics)
        if target !== node && [.dialog, .table, .tree, .list, .row, .cell, .status].contains(semantics.role) {
            target = node; semantics = AccessibilitySemantics(.group); configure(&semantics)
        }
        target.accessibility = semantics
    }
}

public extension View {
    func accessibility(_ configure: @escaping (inout AccessibilitySemantics) -> Void) -> some View {
        modifier(AccessibilityModifier(configure: configure))
    }
    func accessibilityLabel(_ label: String) -> some View { accessibility { $0.label = label } }
    func accessibilityIdentifier(_ identifier: String) -> some View { accessibility { $0.identifier = identifier } }
    func accessibilityHidden(_ hidden: Bool = true) -> some View { accessibility { $0.isHidden = hidden } }
}
