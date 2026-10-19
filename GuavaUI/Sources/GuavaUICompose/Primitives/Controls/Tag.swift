import GuavaUIRuntime

/// Compact labelled chip, optionally removable.
///
/// `Tag` carries content (a filter, a category, an assignee); `Badge` carries
/// status. They look similar on purpose but are separate types so a tag can own
/// a remove action and a badge can never be mistaken for one.
///
/// ```swift
/// Tag("metal") { $0.onRemove = { filters.remove("metal") } }
/// Tag("renderer") { $0.icon = UIIcons.Editor.box; $0.variant = .outline }
/// ```
public struct Tag: _PrimitiveView {
    public enum Variant: Sendable, Hashable {
        case soft
        case solid
        case outline
    }

    public var title: String
    public var tone: StatusTone
    public var variant: Variant
    /// Leading glyph. `nil` keeps the chip text-only.
    public var icon: BundleImageResource?
    public var showsDot: Bool
    public var isEnabled: Bool
    /// When set, a remove button is rendered in the trailing slot.
    public var onRemove: (() -> Void)?

    public init(_ title: String, configure: (inout Self) -> Void = { _ in }) {
        self.title = title
        self.tone = .neutral
        self.variant = .soft
        self.icon = nil
        self.showsDot = false
        self.isEnabled = true
        self.onRemove = nil
        configure(&self)
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) { layout.minWidth = 0; layout.flexShrink = 1 }

    public func _updateNode(_ node: Node) {
        node.isFocusable = false
        node.accessibility = AccessibilitySemantics(.group) {
            $0.label = title
            $0.help = onRemove == nil ? "" : "Remove \(title)"
            $0.state.isEnabled = isEnabled
            $0.combinesChildren = true
        }
    }

    public func _children(for node: Node) -> [any View] {
        let theme = node.theme
        let metrics = Metrics(controlSize: node.compositionValue(of: ControlSizeEnvironment.key))
        let base = tone.color.resolve(theme)
        let disabledInk = SemanticColorRef.onSurfaceDisabled.resolve(theme)
        let style = resolvedStyle(base: base, disabledInk: disabledInk, theme: theme)
        return [
            Row(alignment: .center, spacing: metrics.gap) {
                if let icon {
                    Icon(icon, size: metrics.iconSize, color: style.ink)
                        .flex(0, shrink: 0)
                } else if showsDot {
                    Box {}.frame(width: metrics.dotSize, height: metrics.dotSize)
                        .background(style.ink).cornerRadius(metrics.dotSize / 2)
                        .accessibilityHidden().flex(0, shrink: 0)
                }
                Text(title).font(metrics.font).foregroundColor(style.ink)
                    .flex(0, shrink: 1).frame(minWidth: 0)
                if let onRemove {
                    Button(icon: .resource(UIIcons.Action.x),
                           size: metrics.removeSize,
                           isEnabled: isEnabled,
                           tooltip: "Remove \(title)",
                           action: onRemove)
                        .buttonStyle(.ghost)
                        .controlSize(.mini)
                        .accessibilityLabel("Remove \(title)")
                        .flex(0, shrink: 0)
                }
            }
            .padding(horizontal: metrics.paddingX, vertical: metrics.paddingY)
            .background(style.fill)
            .cornerRadius(theme.radius.sm)
            .border(style.stroke, width: style.strokeWidth)
            .opacity(isEnabled ? 1 : 0.6)
        ]
    }

    private func resolvedStyle(base: Color, disabledInk: Color, theme: Theme) -> Style {
        let ink = isEnabled ? base : disabledInk
        switch variant {
        case .soft:
            return Style(ink: ink, fill: base.multipliedAlpha(0.14), stroke: .clear, strokeWidth: 0)
        case .solid:
            return Style(ink: isEnabled ? tone.ink(onSolid: theme) : disabledInk,
                         fill: base.multipliedAlpha(isEnabled ? 1 : 0.4),
                         stroke: .clear,
                         strokeWidth: 0)
        case .outline:
            return Style(ink: ink,
                         fill: .clear,
                         stroke: base.multipliedAlpha(isEnabled ? 0.45 : 0.2),
                         strokeWidth: 1)
        }
    }

    private struct Style {
        let ink: Color
        let fill: Color
        let stroke: Color
        let strokeWidth: Float
    }
}

extension Tag {
    struct Metrics {
        let font: SemanticFontRef
        let paddingX: Float
        let paddingY: Float
        let gap: Float
        let iconSize: Float
        let dotSize: Float
        let removeSize: Float

        init(controlSize: ControlSize) {
            switch controlSize {
            case .mini:
                font = .caption; paddingX = 5; paddingY = 1.5; gap = 3
                iconSize = 10; dotSize = 5; removeSize = 8
            case .small:
                font = .caption; paddingX = 7; paddingY = 2; gap = 4
                iconSize = 11; dotSize = 5; removeSize = 9
            case .regular:
                font = .label; paddingX = 9; paddingY = 3; gap = 5
                iconSize = 13; dotSize = 6; removeSize = 10
            case .large:
                font = .label; paddingX = 11; paddingY = 4.5; gap = 6
                iconSize = 15; dotSize = 7; removeSize = 12
            }
        }
    }
}
