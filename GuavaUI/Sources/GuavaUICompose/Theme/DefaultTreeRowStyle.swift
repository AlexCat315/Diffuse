import GuavaUIRuntime

/// Tree row default: same density and hierarchy cues as the list style, with
/// enough selection contrast to read as an outline tree in an editor shell.
public struct DefaultTreeRowStyle: TreeRowStyle {
    public init() {}

    public func makeBody(configuration: TreeRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if configuration.isSelected { return t.colors.selection }
            if configuration.isHovered  { return t.colors.stateLayerHover }
            return clear
        }()
        let border: Color = configuration.isSelected ? t.colors.borderStrong : clear
        let borderWidth: Float = configuration.isSelected ? 1 : 0

        return Row(alignment: .center, spacing: 0) {
            Row(alignment: .center, spacing: t.spacing.sm) {
                configuration.content
                Spacer(minLength: 0)
            }
            .flex()
            .padding(horizontal: t.spacing.sm + 1, vertical: t.spacing.xs + 1)
        }
        .background(bg)
        .cornerRadius(t.radius.none)
        .border(border, width: borderWidth)
        .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
