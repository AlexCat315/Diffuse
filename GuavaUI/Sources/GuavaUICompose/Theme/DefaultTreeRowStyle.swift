import GuavaUIRuntime

private struct _TreeRowVisualKey: Equatable, Sendable {
    let background: Color
    let alpha: Float
}

/// Tree row default: same density and hierarchy cues as the list style, with
/// enough selection contrast to read as an outline tree in an editor shell.
public struct DefaultTreeRowStyle: TreeRowStyle {
    public init() {}

    public func makeBody(configuration: TreeRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if configuration.isSelected { return t.colors.selection }
            if configuration.isSearchHit { return t.colors.stateLayerSelected }
            if configuration.isHovered  { return t.colors.stateLayerHover }
            return clear
        }()
        let alpha: Float = configuration.isEnabled ? 1 : 0.55
        let visualKey = _TreeRowVisualKey(background: bg, alpha: alpha)

        return Row(alignment: .center, spacing: 0) {
            Row(alignment: .center, spacing: t.spacing.sm) {
                configuration.content
                Spacer(minLength: 0)
            }
            .flex()
            .padding(horizontal: t.spacing.sm + 1, vertical: t.spacing.xs + 1)
        }
        .background(bg)
        .cornerRadius(t.radius.sm)
        .opacity(alpha)
        .animation(.semantic(.fast, in: t), value: visualKey)
    }
}
