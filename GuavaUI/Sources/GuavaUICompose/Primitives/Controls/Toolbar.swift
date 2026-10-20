import GuavaUIRuntime

public enum ToolbarMetrics {
    public static var height: Float { height(for: .regular) }
    public static var controlHeight: Float { height - 8 }
    public static func height(for size: ControlSize) -> Float { size.buttonHeight + 8 }
}

public enum ToolbarDividerEdge: Sendable, Hashable {
    /// `leading`/`trailing` suit vertical toolbars docked beside content.
    case none, bottom, top, leading, trailing
}

/// Main axis of a toolbar. Vertical toolbars stack commands top to bottom,
/// navigate with Up/Down and open overflow beside the bar.
public enum ToolbarAxis: Sendable, Hashable {
    case horizontal, vertical
}

enum ToolbarAxisEnvironment {
    static let key = CompositionLocal<ToolbarAxis>(defaultValue: .horizontal)
}

/// Groups controls with shared density and arrow-key navigation along the axis.
/// Child inputs get first refusal for caret movement. Disabling the toolbar
/// blocks all hosted input and removes its descendants from focus traversal.
public struct ToolbarOptions {
    public var divider: ToolbarDividerEdge = .bottom
    public var isEnabled = true
    public var label = "Toolbar"
    public var axis: ToolbarAxis = .horizontal
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

struct ToolbarChrome {
    var minimumHeight: Float?
    var verticalPadding: Float = 4
}

struct ToolbarHost<Content: View>: _PrimitiveView {
    let options: ToolbarOptions
    let content: Content
    var chrome = ToolbarChrome()
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.allowsHitTesting = options.isEnabled
        node.accessibility = AccessibilitySemantics(.toolbar) {
            $0.label = options.label; $0.state.isEnabled = options.isEnabled
        }
        node.attachments["toolbar.axis"] = options.axis
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
            let vertical = options.axis == .vertical
            switch event.scancode {
            case Scancode.arrowLeft where !vertical, Scancode.arrowUp where vertical: command = .previous
            case Scancode.arrowRight where !vertical, Scancode.arrowDown where vertical: command = .next
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
            ScrollReveal.reveal(candidates[index])
            return .handled
        }
    }
    func _children(for node: Node) -> [any View] {
        let theme = node.theme
        let size = node.compositionValue(of: ControlSizeEnvironment.key)
        let extent = chrome.minimumHeight ?? ToolbarMetrics.height(for: size)
        let vertical = options.axis == .vertical
        let sideDivider = options.divider == .leading || options.divider == .trailing
        return [Box(direction: sideDivider ? .row : .column, alignItems: .stretch, spacing: 0) {
            if options.divider == .top { Divider() }
            if options.divider == .leading { Divider(axis: .vertical) }
            if vertical {
                Column(alignment: .center, spacing: theme.spacing.xs) { content }
                    .padding(horizontal: chrome.verticalPadding, vertical: theme.spacing.sm)
                    .frame(minWidth: extent)
                    .flex(1, shrink: 1).frame(minHeight: 0)
            } else {
                Row(alignment: .center, spacing: theme.spacing.xs) { content }
                    .padding(horizontal: theme.spacing.sm, vertical: chrome.verticalPadding)
                    .frame(minHeight: extent)
            }
            if options.divider == .trailing { Divider(axis: .vertical) }
            if options.divider == .bottom { Divider() }
        }.compositionLocal(ToolbarAxisEnvironment.key, options.axis).buttonStyle(.ghost).background(SemanticColorRef.surface).opacity(options.isEnabled ? 1 : 0.6)]
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
        let vertical = node.compositionValue(of: ToolbarAxisEnvironment.key) == .vertical
        return [Box(direction: vertical ? .column : .row, alignItems: .center, spacing: 2) { content }
            .padding(horizontal: isBordered && !vertical ? 2 : 0, vertical: isBordered && vertical ? 2 : 0)
            .background(isBordered ? theme.colors.surfaceVariant : .clear)
            .cornerRadius(isBordered ? theme.radius.sm : 0)
            .frame(minWidth: vertical ? size.buttonHeight : nil, minHeight: vertical ? nil : size.buttonHeight)]
    }
}

/// Thin rule between toolbar groups, drawn across the toolbar axis.
public struct ToolbarSeparator: _PrimitiveView {
    public init() {}
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _updateNode(_ node: Node) {}
    public func _children(for node: Node) -> [any View] {
        let theme = node.theme
        if node.compositionValue(of: ToolbarAxisEnvironment.key) == .vertical {
            return [Divider().frame(width: 18, height: 1).padding(vertical: theme.spacing.xs).accessibilityHidden()]
        }
        return [Divider(axis: .vertical).frame(width: 1, height: 18)
            .padding(horizontal: theme.spacing.xs).accessibilityHidden()]
    }
}
