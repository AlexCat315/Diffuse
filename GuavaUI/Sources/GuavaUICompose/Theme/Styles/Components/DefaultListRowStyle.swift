import GuavaUIRuntime

private struct _ListRowVisualKey: Equatable, Sendable {
    let fill: Color
    let alpha: Float
}

/// List row default: a navigation pill on a fixed-height row.
///
/// The highlight is the shared `SelectionAppearance` navigation role — the same
/// fill, radius and insets a sidebar destination uses — so a list and the
/// navigation beside it read as one component instead of two. The row owns its
/// height too: content taller than the slot is centred and clipped instead of
/// pushing the painted row past the one below it.
public struct DefaultListRowStyle: ListRowStyle {
    public init() {}

    public func makeBody(configuration: ListRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let appearance = SelectionAppearance.resolve(.navigation, theme: t)
        let fill = appearance.fill(isSelected: configuration.isSelected,
                                   isHovered: configuration.isHovered,
                                   isPressed: false)
        let alpha: Float = configuration.isEnabled ? 1 : 0.55
        return Row(alignment: .center, spacing: t.spacing.sm) {
            configuration.content
            Spacer(minLength: 0)
        }
        .frame(height: max(0, configuration.rowHeight - 2 * appearance.verticalInset))
        .selectionHighlight(.navigation,
                            isSelected: configuration.isSelected,
                            isHovered: configuration.isHovered)
        .padding(horizontal: appearance.horizontalInset, vertical: 0)
        .opacity(alpha)
        // Keyed on the resolved fill, so a theme switch cross-fades the row at
        // the same speed as a tap changes the selection.
        .animation(.semantic(.fast, in: t), value: _ListRowVisualKey(fill: fill, alpha: alpha))
    }
}