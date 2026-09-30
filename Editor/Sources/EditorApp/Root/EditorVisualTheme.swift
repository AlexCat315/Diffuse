import GuavaUICompose
import GuavaUIRuntime

/// Editor chrome has its own restrained palette and density. Generic GuavaUI
/// apps keep their defaults; all editor panes share this single token source.
enum EditorVisualTheme {
    static func make(dark: Bool) -> Theme {
        var theme = dark ? Theme.defaultDark : Theme.defaultLight
        if !dark {
            theme.colors.background = Color(red: 0xE8, green: 0xEC, blue: 0xF5)
            theme.colors.surface = Color(red: 0xF1, green: 0xF3, blue: 0xFA)
            theme.colors.surfaceVariant = Color(red: 0xE8, green: 0xEC, blue: 0xF5)
            theme.colors.surfaceSunken = Color(red: 0xFA, green: 0xFB, blue: 0xFE)
            theme.colors.surfaceRaised = .white
            theme.colors.onSurface = Color(red: 0x25, green: 0x30, blue: 0x49)
            theme.colors.onSurfaceVariant = Color(red: 0x58, green: 0x65, blue: 0x7F)
            theme.colors.onSurfaceMuted = Color(red: 0x70, green: 0x7D, blue: 0x96)
            theme.colors.border = Color(red: 0xD6, green: 0xDC, blue: 0xE9)
            theme.colors.divider = Color(red: 0xD8, green: 0xDE, blue: 0xEC, alpha: 0xAA)
            theme.colors.accent = Color(red: 0x28, green: 0x64, blue: 0xF5)
            theme.colors.accentMuted = Color(red: 0x28, green: 0x64, blue: 0xF5, alpha: 0x16)
            theme.colors.selection = Color(red: 0x28, green: 0x64, blue: 0xF5, alpha: 0x24)
        }
        theme.radius = RadiusScale(none: 0, sm: 3, md: 4, lg: 6, xl: 8, pill: 9999)
        theme.inputs.background = theme.colors.surfaceSunken
        theme.inputs.backgroundDisabled = theme.colors.surface
        theme.inputs.borderColor = theme.colors.border
        theme.inputs.borderDisabled = theme.colors.divider
        theme.inputs.dividerColor = theme.colors.divider
        theme.inputs.addonBackground = theme.colors.surface
        theme.inputs.radius = 4
        theme.inputs.focusRingWidth = 1.5
        return theme
    }
}
