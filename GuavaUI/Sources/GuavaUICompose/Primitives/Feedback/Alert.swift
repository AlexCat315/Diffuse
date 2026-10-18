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
        /// Neutral grouped surface, with tone reserved for the glyph.
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
            SurfaceReader { surface in
                TextScalerReader { scaler in
                    IconMetricsReader { icons in
                        content(theme: theme, surface: surface, scaler: scaler, iconExtent: icons.size(.medium))
                    }
                }
            }
        }
    }

    private func content(theme: Theme, surface: UIEnvironment, scaler: TextScaler, iconExtent: Float) -> some View {
        let style = resolvedStyle(theme)
        let textInset = showsIcon ? iconExtent + theme.spacing.sm : 0
        return Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Row(alignment: .top, spacing: theme.spacing.sm) {
                Row(alignment: .top, spacing: theme.spacing.sm) {
                    if showsIcon {
                        Box(direction: .row, alignItems: .center, justifyContent: .center) {
                            Icon(icon ?? tone.icon, size: .medium, color: style.iconInk)
                        }
                        .frame(width: iconExtent, height: max(iconExtent, scaler.scale(theme.typography.bodyStrong.lineHeight)))
                        .debugName("alert-icon-slot")
                        .flex(0, shrink: 0).accessibilityHidden()
                    }
                    Text(title).font(.bodyStrong).foregroundColor(style.ink)
                        .flex(0, shrink: 1).frame(minWidth: 0)
                }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                if let onDismiss {
                    Button(icon: .resource(UIIcons.Action.x), size: 14,
                           tooltip: "Dismiss", action: onDismiss)
                        .buttonStyle(.ghost).controlSize(.small).accessibilityLabel("Dismiss")
                }
            }
            if !message.isEmpty {
                Box(direction: .row, alignItems: .flexStart) {
                    Text(message).font(.body).foregroundColor(style.detail)
                }.padding(EdgeInsets(leading: textInset))
            }
            if hasActions {
                ActionGroupLayout(stacks: surface.viewport.widthClass == .compact, alignment: .leading) { actions }
                    .padding(EdgeInsets(top: theme.spacing.xs, leading: textInset))
            }
        }
        .padding(theme.spacing.md)
        .frame(maxWidth: max(0, surface.viewport.width - 32))
        .background(style.fill).cornerRadius(theme.radius.md).border(style.stroke, width: 1)
        .accessibility {
            $0.role = .status; $0.label = title; $0.help = message
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
