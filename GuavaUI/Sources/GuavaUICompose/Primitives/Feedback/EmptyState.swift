import GuavaUIRuntime

/// Explains why a region is empty and offers the one action that fixes it.
///
/// An empty region without a next step is a dead end, so the recovery action is
/// part of the component rather than something every call site has to remember.
/// `prominence` covers the three places an empty state realistically appears:
/// inside a table body, in a full panel, and as a whole page.
///
/// ```swift
/// EmptyState("No projects yet", message: "Create a project to get started.") {
///     Button("Create project") { create() }
/// }
/// ```
/// Vertical weight of an `EmptyState` block.
public enum EmptyStateProminence: Sendable, Hashable {
    /// Fits a table body or a short card: small glyph, tight padding.
    case compact
    /// A panel-sized region. The default.
    case regular
    /// A whole page: large glyph, generous padding.
    case spacious
}

public struct EmptyState<Action: View>: View {
    public typealias Prominence = EmptyStateProminence

    public var title: String
    public var message: String
    /// Glyph override. `nil` uses the bundled "empty container" glyph.
    public var icon: BundleImageResource?
    public var showsIcon: Bool
    public var prominence: Prominence

    private let action: Action
    private let hasAction: Bool

    public init(_ title: String,
                message: String = "",
                configure: (inout Self) -> Void = { _ in },
                @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.icon = nil
        self.showsIcon = true
        self.prominence = .regular
        self.action = action()
        self.hasAction = Action.self != EmptyView.self
        configure(&self)
    }

    public var body: some View {
        ThemeReader { theme in
            let metrics = Metrics(prominence: prominence, theme: theme)
            // The capped column centers itself in whatever space the parent gives.
            Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 0) {
                Column(alignment: .center, spacing: metrics.gap) {
                    if showsIcon {
                        Icon(icon ?? UIIcons.File.inbox, size: metrics.iconSize, color: .onSurfaceMuted)
                            .padding(metrics.chipPadding)
                            .background(theme.colors.surfaceVariant)
                            .cornerRadius(theme.radius.pill)
                            .accessibilityHidden()
                    }
                    Text(title).font(metrics.titleFont).foregroundColor(.onSurface)
                    if !message.isEmpty {
                        Text(message).font(.body).foregroundColor(.onSurfaceMuted)
                    }
                    if hasAction {
                        action.padding(EdgeInsets(top: metrics.actionGap))
                    }
                }
                .frame(maxWidth: metrics.maxWidth)
            }
            .padding(metrics.padding)
            .accessibility {
                $0.role = .group
                $0.label = title
                $0.help = message
            }
        }
    }
}

public extension EmptyState where Action == EmptyView {
    init(_ title: String,
         message: String = "",
         configure: (inout Self) -> Void = { _ in }) {
        self.init(title, message: message, configure: configure, action: { EmptyView() })
    }
}

private struct Metrics {
    let iconSize: Float
    let chipPadding: Float
    let gap: Float
    let padding: Float
    let actionGap: Float
    let titleFont: SemanticFontRef
    let maxWidth: Float

    init(prominence: EmptyStateProminence, theme: Theme) {
        switch prominence {
        case .compact:
            iconSize = 18; chipPadding = 8; gap = 4; padding = theme.spacing.md
            actionGap = theme.spacing.xs; titleFont = .bodyStrong; maxWidth = 320
        case .regular:
            iconSize = 24; chipPadding = 12; gap = 6; padding = theme.spacing.lg
            actionGap = theme.spacing.sm; titleFont = .headline; maxWidth = 380
        case .spacious:
            iconSize = 32; chipPadding = 16; gap = 8; padding = theme.spacing.xl
            actionGap = theme.spacing.md; titleFont = .title; maxWidth = 440
        }
    }
}
