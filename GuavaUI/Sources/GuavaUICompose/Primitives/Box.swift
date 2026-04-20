import GuavaUIRuntime

/// Common alignment vocabulary mapped to Yoga's alignment enums.
public enum HorizontalAlignment: Sendable {
    case leading, center, trailing
}

public enum VerticalAlignment: Sendable {
    case top, center, bottom
}

public enum Alignment: Sendable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing
}

extension HorizontalAlignment {
    var yogaAlign: Align {
        switch self {
        case .leading:  return .flexStart
        case .center:   return .center
        case .trailing: return .flexEnd
        }
    }
}

extension VerticalAlignment {
    var yogaAlign: Align {
        switch self {
        case .top:    return .flexStart
        case .center: return .center
        case .bottom: return .flexEnd
        }
    }
}

/// A flexible container with explicit flex direction. Most layout primitives
/// (`Row`, `Column`) are thin wrappers around `Box`.
public struct Box<Content: View>: _PrimitiveView {
    public let direction: FlexDirection
    public let alignItems: Align
    public let justifyContent: Justify
    public let spacing: Float
    public let content: Content

    public init(direction: FlexDirection = .column,
                alignItems: Align = .stretch,
                justifyContent: Justify = .flexStart,
                spacing: Float = 0,
                @ViewBuilder content: () -> Content) {
        self.direction = direction
        self.alignItems = alignItems
        self.justifyContent = justifyContent
        self.spacing = spacing
        self.content = content()
    }

    public func _makeNode() -> Node { Node() }
    public func _updateNode(_ node: Node) { /* visual props live on modifiers */ }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = direction
        layout.alignItems = alignItems
        layout.justifyContent = justifyContent
        if spacing > 0 {
            layout.setGap(spacing, gutter: .all)
        }
    }

    public var _children: [any View] { [content] }
}

/// Horizontal stack — Box with `flexDirection: .row`.
public struct Row<Content: View>: _PrimitiveView {
    public let alignment: VerticalAlignment
    public let spacing: Float
    public let content: Content

    public init(alignment: VerticalAlignment = .center,
                spacing: Float = 0,
                @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public func _makeNode() -> Node { Node() }
    public func _updateNode(_ node: Node) {}

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .row
        layout.alignItems = alignment.yogaAlign
        if spacing > 0 { layout.setGap(spacing, gutter: .all) }
    }

    public var _children: [any View] { [content] }
}

/// Vertical stack — Box with `flexDirection: .column`.
public struct Column<Content: View>: _PrimitiveView {
    public let alignment: HorizontalAlignment
    public let spacing: Float
    public let content: Content

    public init(alignment: HorizontalAlignment = .leading,
                spacing: Float = 0,
                @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public func _makeNode() -> Node { Node() }
    public func _updateNode(_ node: Node) {}

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = alignment.yogaAlign
        if spacing > 0 { layout.setGap(spacing, gutter: .all) }
    }

    public var _children: [any View] { [content] }
}

/// Greedy spacer that absorbs free space along the parent's main axis.
public struct Spacer: _PrimitiveView {
    public let minLength: Float

    public init(minLength: Float = 0) {
        self.minLength = minLength
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }
    public func _updateNode(_ node: Node) {}

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.flexGrow = 1
        if minLength > 0 {
            // Use minWidth/minHeight on both axes — Yoga ignores the cross-axis one
            // because Spacer doesn't grow there.
            layout.setFlexBasis(minLength)
        }
    }
}
