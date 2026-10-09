import GuavaUIRuntime

private struct _ListRowVisualKey: Equatable, Sendable {
    let background: Color
    let alpha: Float
}

/// One stable row tree lets selection and hover interpolate without replacing
/// the content or resetting its local state.
public struct DefaultListRowStyle: ListRowStyle {
    public init() {}

    public func makeBody(configuration: ListRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let fill = configuration.isSelected ? t.colors.selection
            : configuration.isHovered ? t.colors.stateLayerHover : .clear
        let alpha: Float = configuration.isEnabled ? 1 : 0.55
        return Row(alignment: .center, spacing: t.spacing.sm) {
            configuration.content
            Spacer(minLength: 0)
        }
        .padding(horizontal: t.spacing.md, vertical: t.spacing.xs + 1)
        .background(fill)
        .opacity(alpha)
        .animation(.semantic(.fast, in: t), value: _ListRowVisualKey(background: fill, alpha: alpha))
    }
}
