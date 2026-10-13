import GuavaUIRuntime

private struct _TreeRowVisualKey: Equatable, Sendable {
    let background: Color
    let alpha: Float
}

/// Tree row default: same density and hierarchy cues as the list style, with
/// enough selection contrast to read as an outline tree in an editor shell.
///
/// The highlight is the shared `SelectionAppearance` data-row role — an
/// edge-to-edge band, because a tree's rows share horizontal rules with their
/// indent guides and a pill would break the column they line up in.
public struct DefaultTreeRowStyle: TreeRowStyle {
    public init() {}

    public func makeBody(configuration: TreeRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let selection = SelectionAppearance.resolve(.dataRow, theme: t)
        let bg: Color = configuration.isSearchHit && !configuration.isSelected
            ? t.colors.stateLayerSelected
            : selection.fill(isSelected: configuration.isSelected,
                             isHovered: false,
                             isPressed: false)
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
