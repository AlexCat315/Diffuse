import GuavaUIRuntime

/// Inline feedback block: a status glyph, a title, an optional explanation,
/// optional actions and an optional dismissal.
///
/// The glyph is part of the content, not decoration — it carries the same
/// meaning as the tone's colour, so the block still reads correctly when the
/// palette is monochrome or the reader cannot distinguish the hues.
///
/// ```swift
/// Alert("Import failed", message: "The selected asset format is unsupported.", tone: .danger)
///
/// Alert("Update available", message: "Restart to use the new version.", tone: .info) {
///     $0.onDismiss = { isPresented = false }
/// } actions: {
///     Button("Restart now") { restart() }.buttonStyle(.secondary)
/// }
/// ```
public struct Alert<Actions: View>: View {
    public enum Variant: Sendable, Hashable {
        /// Tinted wash. The default — it reads as part of the page.
        case soft
        /// Transparent with a tinted edge, for stacking inside a bordered panel.
        case outline
        /// Fully filled with the tone. Reserve for a single blocking message.
        case filled
    }

    public var title: String
    public var message: String
    public var tone: StatusTone
    public var variant: Variant
    /// Glyph override. `nil` uses the tone's glyph.
    public var icon: BundleImageResource?
    public var showsIcon: Bool
    /// When set, a close button is rendered in the trailing slot.
    public var onDismiss: (() -> Void)?

    private let actions: Actions
    private let hasActions: Bool

    public init(_ title: String,
                message: String = "",
                tone: StatusTone = .info,
                configure: (inout Self) -> Void = { _ in },
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.tone = tone
        self.variant = .soft
        self.icon = nil
        self.showsIcon = true
        self.onDismiss = nil
        self.actions = actions()
        self.hasActions = Actions.self != EmptyView.self
        configure(&self)
    }

    public var body: some View {
        ThemeReader { theme in
            let style = resolvedStyle(theme)
            let iconExtent = theme.icons.medium
            let textInset = showsIcon ? iconExtent + theme.spacing.sm : 0
            Row(alignment: .top, spacing: theme.spacing.sm) {
                Column(alignment: .leading, spacing: 4) {
                    Row(alignment: .center, spacing: theme.spacing.sm) {
                        if showsIcon {
                            // The glyph belongs to the title line, so center it
                            // in that line box and use the same extent to indent
                            // the message and actions onto the title's edge.
                            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                                Icon(icon ?? tone.icon, size: .medium, color: style.iconInk)
                            }
                            .frame(width: iconExtent, height: theme.typography.bodyStrong.lineHeight)
                            .flex(0, shrink: 0)
                            .accessibilityHidden()
                        }
                        Text(title).font(.bodyStrong).foregroundColor(style.ink)
                    }
                    if !message.isEmpty {
                        Box(direction: .row, alignItems: .flexStart) {
                            Text(message).font(.body).foregroundColor(style.detail)
                        }
                        .padding(EdgeInsets(leading: textInset))
                    }
                    if hasActions {
                        Row(alignment: .center, spacing: theme.spacing.xs) { actions }
                            .padding(EdgeInsets(top: theme.spacing.xs, leading: textInset))
                    }
                }
                .flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                if let onDismiss {
                    Button(icon: .resource(UIIcons.Action.x),
                           size: 14,
                           tooltip: "Dismiss",
                           action: onDismiss)
                        .buttonStyle(.ghost)
                        .controlSize(.small)
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(theme.spacing.md)
            .background(style.fill)
            .cornerRadius(theme.radius.md)
            .border(style.stroke, width: 1)
            .accessibility {
                $0.role = .status
                $0.label = title
                $0.help = message
            }
        }
    }

    private func resolvedStyle(_ theme: Theme) -> Style {
        let base = tone.color.resolve(theme)
        switch variant {
        case .soft:
            // iOS inline status card: neutral grouped surface, tone reserved
            // for the glyph and hairline instead of tinting the whole block.
            return Style(ink: theme.colors.onSurface,
                         iconInk: base,
                         detail: theme.colors.onSurfaceVariant,
                         fill: theme.colors.surfaceRaised,
                         stroke: theme.colors.border)
        case .outline:
            return Style(ink: theme.colors.onSurface,
                         iconInk: base,
                         detail: theme.colors.onSurfaceVariant,
                         fill: .clear,
                         stroke: base.multipliedAlpha(0.45))
        case .filled:
            let solidInk = tone.ink(onSolid: theme)
            return Style(ink: solidInk,
                         iconInk: solidInk,
                         detail: solidInk.multipliedAlpha(0.88),
                         fill: base,
                         stroke: .clear)
        }
    }

    private struct Style {
        let ink: Color
        let iconInk: Color
        let detail: Color
        let fill: Color
        let stroke: Color
    }
}

public extension Alert where Actions == EmptyView {
    init(_ title: String,
         message: String = "",
         tone: StatusTone = .info,
         configure: (inout Self) -> Void = { _ in }) {
        self.init(title, message: message, tone: tone, configure: configure, actions: { EmptyView() })
    }
}
