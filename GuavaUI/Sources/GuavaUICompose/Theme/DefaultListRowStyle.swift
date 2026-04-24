import GuavaUIRuntime

private struct _ListRowVisualKey: Equatable, Sendable {
    let background: Color?
    let border: Color?
    let borderWidth: Float
    let alpha: Float
}

/// List row default: tighter desktop density, a clearer selected fill, and a
/// small-radius hover state so lists read as rows in a data tool rather than
/// as a pile of pills.
public struct DefaultListRowStyle: ListRowStyle {
    public init() {}

    public func makeBody(configuration: ListRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let animation = Animation.semantic(.fast, in: t)
        let background: Color? = {
            if configuration.isSelected { return t.colors.selection }
            if configuration.isHovered { return t.colors.stateLayerHover }
            return nil
        }()
        let border: Color? = configuration.isSelected ? t.colors.borderStrong : nil
        let borderWidth: Float = configuration.isSelected ? 1 : 0
        let alpha: Float = configuration.isEnabled ? 1 : 0.55
        let visualKey = _ListRowVisualKey(background: background,
                                          border: border,
                                          borderWidth: borderWidth,
                                          alpha: alpha)

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
                .opacity(alpha)
                .animation(animation, value: visualKey)
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
                .opacity(alpha)
                .animation(animation, value: visualKey)
            )
        }
        return AnyView(
            Row(alignment: .center, spacing: t.spacing.sm) {
                configuration.content
                Spacer(minLength: 0)
            }
            .padding(horizontal: t.spacing.md, vertical: t.spacing.xs + 1)
            .opacity(alpha)
            .animation(animation, value: visualKey)
        )
    }
}
