import GuavaUIRuntime

/// Compact ghost-flavoured button style used exclusively for the close-X
/// glyph rendered inside `DockTabBar`. Differs from `GhostButtonStyle` in
/// that it forces a square frame sized by `DockAppearance.closeButtonSize`,
/// drops horizontal padding entirely, uses the small radius scale, and
/// tints the label by tab activation state instead of always applying
/// `.onSurface`.
///
/// State-layer overlays come straight from the active theme so a hover or
/// press tint follows whatever palette the host installed (matches the
/// rest of the Dock chrome). The style still routes through the standard
/// `.animation(.buttonInteraction, value: configuration.interactionKey)`
/// hook so palette swaps cross-fade like every other built-in button.
struct _DockTabCloseButtonStyle: ButtonStyle {
    let isActive: Bool
    let size: Float

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if !configuration.isEnabled { return clear }
            if configuration.isPressed  { return theme.colors.stateLayerPressed }
            if configuration.isHovered  { return theme.colors.stateLayerHover }
            return clear
        }()
        let labelColor: SemanticColorRef = isActive ? .onSurface : .onSurfaceMuted

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(.bodyStrong)
                .foregroundColor(labelColor)
        }
        .frame(width: size, height: size)
        .background(bg)
        .cornerRadius(theme.radius.sm)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}

struct _DockTabIconButtonStyle: ButtonStyle {
    let size: Float

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if !configuration.isEnabled { return clear }
            if configuration.isPressed { return theme.colors.stateLayerPressed }
            if configuration.isHovered { return theme.colors.stateLayerHover }
            return clear
        }()

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
        }
        .frame(width: size, height: size)
        .background(bg)
        .cornerRadius(theme.radius.sm)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}
