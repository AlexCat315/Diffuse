import GuavaUIRuntime

/// Panel default — the "floating island" idiom: the panel body is a
/// rounded (radius.xl) slab of `surfaceSunken`, *darker* than the window
/// canvas, with NO border and no header fill. Separation between neighbouring
/// panels comes from the canvas showing through the gutters, not from lines.
/// The header is a 34px row with a muted 12px title; active panels brighten
/// the title rather than repainting the header.
public struct DefaultPanelStyle: PanelStyle {
    public init() {}

    public func makeBody(configuration: PanelStyleConfiguration) -> some View {
        let t = configuration.theme
        let titleColor: SemanticColorRef = configuration.isActive ? .onSurface : .onSurfaceMuted

        return Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: t.spacing.sm) {
                Text(configuration.title)
                    .font(SemanticFontRef.label)
                    .foregroundColor(titleColor)
                Spacer(minLength: 0)
                configuration.accessory
            }
            .padding(horizontal: t.spacing.lg)
            .frame(height: 34)

            Box(direction: .column, alignItems: .stretch) {
                configuration.content
                    .flex()
            }
            .flex()
            .padding(EdgeInsets(top: 0,
                                leading: t.spacing.md,
                                bottom: t.spacing.md,
                                trailing: t.spacing.md))
        }
        .background(SemanticColorRef.surfaceSunken)
        .cornerRadius(t.radius.xl)
        .clipped()
    }
}
