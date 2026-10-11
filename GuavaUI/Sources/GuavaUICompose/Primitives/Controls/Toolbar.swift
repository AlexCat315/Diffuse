import GuavaUIRuntime

public enum ToolbarMetrics {
    public static let height: Float = 36
    public static var controlHeight: Float { height - 8 }
    public static func height(for size: ControlSize) -> Float { size.buttonHeight + 8 }
}

public enum ToolbarDividerEdge: Sendable, Hashable {
    case none, bottom, top
}

/// Groups controls with shared density and horizontal keyboard navigation.
/// Child inputs get first refusal for caret movement. Disabling the toolbar
/// blocks all hosted input and removes its descendants from focus traversal.
public struct ToolbarOptions {
    public var divider: ToolbarDividerEdge = .bottom
    public var isEnabled = true
    public var label = "Toolbar"
    public init() {}
}

public struct Toolbar<Content: View>: View {
    public var options = ToolbarOptions()
    public let content: Content
    public init(configure: (inout ToolbarOptions) -> Void = { _ in }, @ViewBuilder content: () -> Content) {
        self.content = content(); configure(&options)
    }
    public var body: some View { ToolbarHost(options: options, content: content) }
}

private struct ToolbarHost<Content: View>: _PrimitiveView {
    let options: ToolbarOptions
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.allowsHitTesting = options.isEnabled
        node.accessibility = AccessibilitySemantics(.toolbar) { $0.label = options.label; $0.state.isEnabled = options.isEnabled }
        if !options.isEnabled {
            if let captured = PointerCaptureHolder.current?.target,
               FocusChainHolder.current?.contains(captured, in: node) == true { PointerCaptureHolder.current?.release() }
            if let focused = FocusChainHolder.current?.focused,
               FocusChainHolder.current?.contains(focused, in: node) == true { FocusChainHolder.current?.clear() }
        }
        InteractionRegistryHolder.current?.setKey(node) { [weak node] event, phase in
            guard options.isEnabled, phase == .bubble, event.modifiers.isEmpty, let node,
                  let focused = FocusChainHolder.current?.focused else { return .ignored }
            let command: SelectionNavigation
            switch event.scancode {
            case Scancode.arrowLeft: command = .previous
            case Scancode.arrowRight: command = .next
            case Scancode.home: command = .first
            case Scancode.end: command = .last
            default: return .ignored
            }
            func items(in candidate: Node) -> [Node] {
                guard candidate.acceptsSubtreeInput else { return [] }
                return (candidate.isFocusable && candidate.isTabStop ? [candidate] : []) + candidate.children.flatMap(items)
            }
            let candidates = items(in: node)
            guard let index = command.destination(in: Array(candidates.indices),
                from: candidates.firstIndex(where: { $0 === focused })) else { return .ignored }
            FocusChainHolder.current?.focus(candidates[index])
            return .handled
        }
    }
    func _children(for node: Node) -> [any View] {
        let theme = node.theme
        let size = node.compositionValue(of: ControlSizeEnvironment.key)
        return [Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if options.divider == .top { Divider() }
            Row(alignment: .center, spacing: theme.spacing.xs) { content }
                .padding(horizontal: theme.spacing.sm).frame(height: ToolbarMetrics.height(for: size))
            if options.divider == .bottom { Divider() }
        }.buttonStyle(.ghost).background(SemanticColorRef.surface).opacity(options.isEnabled ? 1 : 0.6)]
    }
}

public struct ToolbarGroup<Content: View>: View {
    public var isBordered = false
    public var label = ""
    public let content: Content
    public init(isBordered: Bool = false, label: String = "", @ViewBuilder content: () -> Content) {
        self.isBordered = isBordered; self.label = label; self.content = content()
    }
    public var body: some View { ToolbarGroupHost(isBordered: isBordered, label: label, content: content) }
}

private struct ToolbarGroupHost<Content: View>: _PrimitiveView {
    let isBordered: Bool
    let label: String
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.accessibility = AccessibilitySemantics(.group) { $0.label = label }
    }
    func _children(for node: Node) -> [any View] {
        let size = node.compositionValue(of: ControlSizeEnvironment.key)
        let theme = node.theme
        return [Row(alignment: .center, spacing: 2) { content }
            .padding(horizontal: isBordered ? 2 : 0)
            .background(isBordered ? theme.colors.surfaceVariant : .clear)
            .cornerRadius(isBordered ? theme.radius.sm : 0)
            .frame(height: size.buttonHeight)]
    }
}

public struct ToolbarSeparator: View {
    public init() {}
    public var body: some View {
        ThemeReader { theme in
            Divider(axis: .vertical).frame(width: 1, height: 18)
                .padding(horizontal: theme.spacing.xs).accessibilityHidden()
        }
    }
}
