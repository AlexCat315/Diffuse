import GuavaUIRuntime

/// Shared metrics for toolbar chrome.
///
/// Kept outside `Toolbar` so `Toolbar`, `ToolbarGroup` and `ToolbarSeparator`
/// agree on one height without any of them owning it — a `static let` on a
/// generic type cannot be shared, and a bar with two control heights looks
/// broken.
public enum ToolbarMetrics {
    public static let height: Float = 36
    /// Height of the controls inside a group: the bar height minus its padding.
    public static var controlHeight: Float { height - 8 }
}

/// Which edge of a `Toolbar` is separated from the content.
public enum ToolbarDividerEdge: Sendable, Hashable {
    case none
    /// Separator under the bar. Use it when the bar sits above content.
    case bottom
    /// Separator above the bar. Use it when the bar sits below content.
    case top
}

/// Horizontal bar of controls above or beside the content they act on.
///
/// A toolbar is mostly about what it enforces: one height, one spacing rhythm,
/// and consistent separators. Callers supply the items; the bar owns the frame,
/// the divider and the enabled state so every toolbar in an app lines up.
///
/// ```swift
/// Toolbar {
///     ToolbarGroup { playButton; stopButton }
///     ToolbarSeparator()
///     Spacer()
///     ToolbarGroup(isBordered: true) { zoomOutButton; zoomInButton }
/// }
/// ```
public struct Toolbar<Content: View>: View {
    public var divider: ToolbarDividerEdge
    public var isEnabled: Bool
    public let content: Content

    public init(configure: (inout Self) -> Void = { _ in },
                @ViewBuilder content: () -> Content) {
        self.divider = .bottom
        self.isEnabled = true
        self.content = content()
        configure(&self)
    }

    public var body: some View {
        ThemeReader { theme in
            Column(alignment: .leading, spacing: 0) {
                if divider == .top {
                    AnyView(Divider())
                }
                AnyView(Row(alignment: .center, spacing: theme.spacing.xs) { content }
                    .padding(horizontal: theme.spacing.sm, vertical: 0)
                    .frame(height: ToolbarMetrics.height))
                if divider == .bottom {
                    AnyView(Divider())
                }
            }
            .background(SemanticColorRef.surface)
            .opacity(isEnabled ? 1 : 0.6)
            .accessibility { $0.role = .group; $0.label = "Toolbar"; $0.state.isEnabled = isEnabled }
        }
    }
}

/// Runs of controls that belong together, separated from their neighbours.
///
/// Grouping is what makes a toolbar scannable: without it a row of ten icons
/// reads as ten unrelated actions.
public struct ToolbarGroup<Content: View>: View {
    /// Paints a container so the group reads as one segmented control.
    public var isBordered: Bool
    public let content: Content

    public init(isBordered: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.isBordered = isBordered
        self.content = content()
    }

    public var body: some View {
        ThemeReader { theme in
            let fill: Color = isBordered ? SemanticColorRef.surfaceVariant.resolve(theme) : .clear
            Row(alignment: .center, spacing: 2) { content }
                .padding(horizontal: isBordered ? 2 : 0, vertical: 0)
                .background(fill)
                .cornerRadius(isBordered ? theme.radius.sm : 0)
                .frame(height: ToolbarMetrics.controlHeight)
                .accessibility { $0.role = .group; $0.combinesChildren = true }
        }
    }
}

/// Vertical rule that separates toolbar groups.
///
/// Inset from the bar's edges rather than full height: a full-height rule
/// collides visually with the bar's own bottom divider and makes the bar look
/// like a table header.
public struct ToolbarSeparator: View {
    public init() {}

    public var body: some View {
        ThemeReader { theme in
            Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 0) {
                Box(direction: .row) { EmptyView() }
                    .frame(width: 1, height: 18)
                    .background(SemanticColorRef.border)
            }
            .frame(width: theme.spacing.sm, height: ToolbarMetrics.height)
            .accessibilityHidden()
        }
    }
}
