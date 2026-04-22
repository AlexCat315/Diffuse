import GuavaUIRuntime

/// List row default: tighter desktop density, a clearer selected fill, and a
/// small-radius hover state so lists read as rows in a data tool rather than
/// as a pile of pills.
public struct DefaultListRowStyle: ListRowStyle {
    public init() {}

    public func makeBody(configuration: ListRowStyleConfiguration) -> some View {
        let t = configuration.theme

        if configuration.isSelected {
            return AnyView(
                Row(alignment: .center, spacing: t.spacing.sm) {
                    configuration.content
                    Spacer(minLength: 0)
                }
                .padding(horizontal: t.spacing.md, vertical: t.spacing.xs + 1)
                .background(t.colors.selection)
                .cornerRadius(t.radius.none)
                .border(t.colors.borderStrong, width: 1)
                .opacity(configuration.isEnabled ? 1 : 0.55)
            )
        }
        if configuration.isHovered {
            return AnyView(
                Row(alignment: .center, spacing: t.spacing.sm) {
                    configuration.content
                    Spacer(minLength: 0)
                }
                .padding(horizontal: t.spacing.md, vertical: t.spacing.xs + 1)
                .background(t.colors.stateLayerHover)
                .cornerRadius(t.radius.none)
                .opacity(configuration.isEnabled ? 1 : 0.55)
            )
        }
        return AnyView(
            Row(alignment: .center, spacing: t.spacing.sm) {
                configuration.content
                Spacer(minLength: 0)
            }
            .padding(horizontal: t.spacing.md, vertical: t.spacing.xs + 1)
            .opacity(configuration.isEnabled ? 1 : 0.55)
        )
    }
}
