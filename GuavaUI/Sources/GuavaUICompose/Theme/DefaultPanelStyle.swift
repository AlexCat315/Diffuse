import GuavaUIRuntime

/// Panel default: rounded surface with a labelled header bar and a divider
/// separating the content area. Header swaps to `surface` when active to
/// visually pop the focused panel within a multi-panel layout.
public struct DefaultPanelStyle: PanelStyle {
    public init() {}

    public func makeBody(configuration: PanelStyleConfiguration) -> some View {
        let t = configuration.theme
        let headerBg = configuration.isActive ? t.colors.surface : t.colors.surfaceVariant

        return Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: t.spacing.sm) {
                Text(configuration.title)
                    .font(SemanticFontRef.label)
                    .foregroundColor(SemanticColorRef.onSurfaceVariant)
                Spacer(minLength: 0)
                configuration.accessory
            }
            .padding(horizontal: t.spacing.md)
            .frame(height: 36)
            .background(headerBg)

            Divider()

            Box(direction: .column, alignItems: .stretch) {
                configuration.content
            }
            .flex()
            .padding(EdgeInsets(top: t.spacing.md,
                                leading: t.spacing.md,
                                bottom: t.spacing.md,
                                trailing: t.spacing.md))
        }
        .background(SemanticColorRef.surface)
        .cornerRadius(t.radius.lg)
        .clipped()
    }
}
