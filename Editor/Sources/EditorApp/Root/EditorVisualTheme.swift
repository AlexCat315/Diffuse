import GuavaUICompose
import GuavaUIRuntime

/// Editor chrome has its own restrained palette and density. Generic GuavaUI
/// apps keep their defaults; all editor panes share this single token source.
enum EditorVisualTheme {
    static func make(dark: Bool) -> Theme {
        var theme = dark ? Theme.defaultDark : Theme.defaultLight
        if dark {
            theme.colors.background = Color(red: 0x10, green: 0x17, blue: 0x25)
            theme.colors.surface = EditorCodePalette.background
            theme.colors.surfaceVariant = EditorCodePalette.selectedTab
            theme.colors.surfaceSunken = EditorCodePalette.gutter
            theme.colors.surfaceRaised = Color(red: 0x23, green: 0x30, blue: 0x46)
            theme.colors.onSurface = EditorCodePalette.foreground
            theme.colors.onSurfaceVariant = Color(red: 0xA8, green: 0xB6, blue: 0xCD)
            theme.colors.onSurfaceMuted = EditorCodePalette.muted
            theme.colors.border = Color(red: 0x3A, green: 0x46, blue: 0x60)
            theme.colors.divider = Color(red: 0x3A, green: 0x46, blue: 0x60, alpha: 0xAA)
            theme.colors.accent = Color(red: 0x6A, green: 0x9C, blue: 0xFF)
            theme.colors.accentMuted = Color(red: 0x6A, green: 0x9C, blue: 0xFF, alpha: 0x22)
            theme.colors.selection = Color(red: 0x6A, green: 0x9C, blue: 0xFF, alpha: 0x30)
        } else {
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

/// Base colors for the editor's dark theme. Source panes resolve their colors
/// through the active semantic theme, including the light palette.
enum EditorCodePalette {
    static let background = Color(red: 0x1A, green: 0x22, blue: 0x32)
    static let gutter = Color(red: 0x15, green: 0x1C, blue: 0x2A)
    static let header = Color(red: 0x1D, green: 0x25, blue: 0x35)
    static let selectedTab = Color(red: 0x28, green: 0x32, blue: 0x47)
    static let foreground = Color(red: 0xDA, green: 0xE2, blue: 0xF2)
    static let muted = Color(red: 0x95, green: 0xA3, blue: 0xBE)
    static let lineNumber = Color(red: 0x72, green: 0x80, blue: 0x9A)
    static let accent = Color(red: 0x77, green: 0xA8, blue: 0xFF)
}
