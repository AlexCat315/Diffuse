import GuavaUIRuntime

/// Panel default: compact tool chrome with a recessed inactive header, a
/// clearer active header, and a border that separates the panel from its
/// neighbors without introducing card-like softness.
public struct DefaultPanelStyle: PanelStyle {
    public init() {}

    public func makeBody(configuration: PanelStyleConfiguration) -> some View {
        let t = configuration.theme
        let headerBg = configuration.isActive ? t.colors.surfaceVariant : t.colors.surfaceSunken
        let titleColor: SemanticColorRef = configuration.isActive ? .onSurface : .onSurfaceVariant

        return Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: t.spacing.sm) {
                Text(configuration.title)
                    .font(SemanticFontRef.label)
                    .foregroundColor(titleColor)
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
        .cornerRadius(t.radius.none)
        .border(t.colors.border, width: 1)
        .clipped()
    }
}
