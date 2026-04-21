import GuavaUIRuntime

/// List row default: padded row with a rounded selection fill. Hovered rows
/// preview the selection tint at lower opacity so users see the affordance
/// before clicking.
public struct DefaultListRowStyle: ListRowStyle {
    public init() {}

    public func makeBody(configuration: ListRowStyleConfiguration) -> some View {
        let t = configuration.theme

        // Resting rows skip `.background` entirely so the row's host node
        // remains "background-less" — handy for tests that count selected
        // rows by walking for non-nil `backgroundColor`.
        if configuration.isSelected {
            return AnyView(
                Row(alignment: .center, spacing: t.spacing.sm) {
                    configuration.content
                    Spacer(minLength: 0)
                }
                .padding(horizontal: t.spacing.md, vertical: t.spacing.sm)
                .background(t.colors.selection)
                .cornerRadius(t.radius.sm)
                .opacity(configuration.isEnabled ? 1 : 0.55)
            )
        }
        if configuration.isHovered {
            return AnyView(
                Row(alignment: .center, spacing: t.spacing.sm) {
                    configuration.content
                    Spacer(minLength: 0)
                }
                .padding(horizontal: t.spacing.md, vertical: t.spacing.sm)
                .background(t.colors.selection.mixed(with: t.colors.surface, amount: 0.7))
                .cornerRadius(t.radius.sm)
                .opacity(configuration.isEnabled ? 1 : 0.55)
            )
        }
        return AnyView(
            Row(alignment: .center, spacing: t.spacing.sm) {
                configuration.content
                Spacer(minLength: 0)
            }
            .padding(horizontal: t.spacing.md, vertical: t.spacing.sm)
            .opacity(configuration.isEnabled ? 1 : 0.55)
        )
    }
}
