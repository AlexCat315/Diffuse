import GuavaUIRuntime

/// Compact, non-interactive status label.
///
/// Three variants trade emphasis against noise: `.soft` reads as a tinted chip
/// inside dense content, `.solid` as a single callout, `.outline` as a quiet
/// marker beside an already-bordered surface. Padding, glyph size and type
/// follow the shared `.controlSize` provider, so one badge definition serves a
/// dense table cell and a page header.
///
/// ```swift
/// Badge("Running", tone: .success)
/// Badge("Deprecated", tone: .warning) { $0.variant = .outline }
/// Badge("3 failures", tone: .danger) { $0.showsDot = true }
/// ```
public struct Badge: _PrimitiveView {
    public enum Variant: Sendable, Hashable {
        case soft
        case solid
        case outline
    }

    public var title: String
    public var tone: StatusTone
    public var variant: Variant
    /// Leading glyph override. `nil` keeps the chip text-only.
    public var icon: BundleImageResource?
    /// Leading status dot. Ignored when `icon` is set — a dot and a glyph
    /// compete for the same slot.
    public var showsDot: Bool
    public var isEnabled: Bool

    public init(_ title: String,
                tone: StatusTone = .neutral,
                configure: (inout Self) -> Void = { _ in }) {
        self.title = title
        self.tone = tone
        self.variant = .soft
        self.icon = nil
        self.showsDot = false
        self.isEnabled = true
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
        node.accessibility = AccessibilitySemantics(.staticText) {
            $0.label = title
            $0.value = String(describing: tone).capitalized
            $0.state.isEnabled = isEnabled
            $0.combinesChildren = true
        }
    }

    public func _children(for node: Node) -> [any View] {
        let theme = node.theme
        let metrics = Metrics(controlSize: node.compositionValue(of: ControlSizeEnvironment.key))
        let base = tone.color.resolve(theme)
        let disabledInk = SemanticColorRef.onSurfaceDisabled.resolve(theme)
        let ink: Color
        let fill: Color
        let stroke: Color
        let strokeWidth: Float
        switch variant {
        case .soft:
            ink = isEnabled ? base : disabledInk
            fill = base.multipliedAlpha(0.14)
            stroke = .clear
            strokeWidth = 0
        case .solid:
            ink = isEnabled ? tone.ink(onSolid: theme) : disabledInk
            fill = base.multipliedAlpha(isEnabled ? 1 : 0.4)
            stroke = .clear
            strokeWidth = 0
        case .outline:
            ink = isEnabled ? base : disabledInk
            fill = .clear
            stroke = base.multipliedAlpha(isEnabled ? 0.45 : 0.2)
            strokeWidth = 1
        }
        // No title: a bare status dot (for activity feeds and list rows),
        // not an empty pill.
        if title.isEmpty, icon == nil, showsDot {
            let size = metrics.dotSize + 3
            return [Box {}.frame(width: size, height: size).background(isEnabled ? base : disabledInk).cornerRadius(size / 2)]
        }
        return [
            Row(alignment: .center, spacing: metrics.gap) {
                if let icon {
                    Icon(icon, size: metrics.iconSize, color: ink)
                        .flex(0, shrink: 0)
                } else if showsDot {
                    // A drawn disc: the dot glyph fills only a fraction of its icon box.
                    Box {}.frame(width: metrics.dotSize, height: metrics.dotSize)
                        .background(ink).cornerRadius(metrics.dotSize / 2)
                        .accessibilityHidden().flex(0, shrink: 0)
                }
                Text(title).font(metrics.font).foregroundColor(ink)
                    .flex(0, shrink: 1).frame(minWidth: 0)
            }
            .padding(horizontal: metrics.paddingX, vertical: metrics.paddingY)
            .background(fill)
            .cornerRadius(theme.radius.sm)
            .border(stroke, width: strokeWidth)
            .opacity(isEnabled ? 1 : 0.6)
        ]
    }
}

private struct Metrics {
    let font: SemanticFontRef
    let paddingX: Float
    let paddingY: Float
    let gap: Float
    let iconSize: Float
    let dotSize: Float

    init(controlSize: ControlSize) {
        switch controlSize {
        case .mini:
            font = .caption; paddingX = 5; paddingY = 1.5; gap = 3; iconSize = 10; dotSize = 5
        case .small:
            font = .caption; paddingX = 6; paddingY = 2; gap = 4; iconSize = 11; dotSize = 5
        case .regular:
            font = .label; paddingX = 8; paddingY = 3; gap = 5; iconSize = 13; dotSize = 6
        case .large:
            font = .label; paddingX = 10; paddingY = 4.5; gap = 6; iconSize = 15; dotSize = 7
        }
    }
}
