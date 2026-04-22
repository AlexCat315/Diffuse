import GuavaUIRuntime

/// Tree row default: depth-indented row with a chevron disclosure slot and
/// the same selection / hover treatment as `DefaultListRowStyle`. The
/// disclosure glyph is rendered as a `Text` chevron; Step 8 will swap it for
/// `Image(systemName:)` once that asset pipeline lands.
public struct DefaultTreeRowStyle: TreeRowStyle {
    public init() {}

    public func makeBody(configuration: TreeRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if configuration.isSelected { return t.colors.stateLayerSelected }
            if configuration.isHovered  { return t.colors.stateLayerHover }
            return clear
        }()

        return Row(alignment: .center, spacing: 0) {
            Row(alignment: .center, spacing: t.spacing.sm) {
                configuration.content
                Spacer(minLength: 0)
            }
            .flex()
            .padding(horizontal: t.spacing.sm, vertical: t.spacing.sm)
        }
        .background(bg)
        .cornerRadius(t.radius.sm)
        .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
