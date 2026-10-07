import GuavaUICompose
import GuavaUIRuntime

/// Editor chrome has its own restrained palette and density. Generic GuavaUI
/// apps keep their defaults; all editor panes share this single token source.
enum EditorVisualTheme {
    static func make(dark: Bool) -> Theme {
        var theme = dark ? Theme.defaultDark : Theme.defaultLight
        if dark {
            theme.colors.background = Color(red: 0x17, green: 0x1A, blue: 0x1B)
            theme.colors.surface = EditorCodePalette.background
            theme.colors.surfaceVariant = EditorCodePalette.selectedTab
            theme.colors.surfaceSunken = EditorCodePalette.gutter
            theme.colors.surfaceRaised = Color(red: 0x2B, green: 0x30, blue: 0x31)
            theme.colors.onSurface = EditorCodePalette.foreground
            theme.colors.onSurfaceVariant = Color(red: 0xAF, green: 0xB7, blue: 0xB5)
            theme.colors.onSurfaceMuted = EditorCodePalette.muted
            theme.colors.border = Color(red: 0x38, green: 0x40, blue: 0x3D)
            theme.colors.divider = Color(red: 0x38, green: 0x40, blue: 0x3D, alpha: 0xAA)
            theme.colors.accent = Color(red: 0x62, green: 0xB4, blue: 0x88)
            theme.colors.accentMuted = Color(red: 0x62, green: 0xB4, blue: 0x88, alpha: 0x22)
            theme.colors.selection = Color(red: 0x62, green: 0xB4, blue: 0x88, alpha: 0x30)
        } else {
            theme.colors.background = Color(red: 0xE9, green: 0xED, blue: 0xEA)
            theme.colors.surface = Color(red: 0xF3, green: 0xF5, blue: 0xF3)
            theme.colors.surfaceVariant = Color(red: 0xE9, green: 0xED, blue: 0xEA)
            theme.colors.surfaceSunken = Color(red: 0xFC, green: 0xFD, blue: 0xFC)
            theme.colors.surfaceRaised = .white
            theme.colors.onSurface = Color(red: 0x25, green: 0x30, blue: 0x2B)
            theme.colors.onSurfaceVariant = Color(red: 0x57, green: 0x65, blue: 0x5E)
            theme.colors.onSurfaceMuted = Color(red: 0x6B, green: 0x7A, blue: 0x71)
            theme.colors.border = Color(red: 0xD2, green: 0xDB, blue: 0xD5)
            theme.colors.divider = Color(red: 0xD5, green: 0xDD, blue: 0xD8, alpha: 0xAA)
            theme.colors.accent = Color(red: 0x27, green: 0x7B, blue: 0x50)
            theme.colors.accentMuted = Color(red: 0x27, green: 0x7B, blue: 0x50, alpha: 0x16)
            theme.colors.selection = Color(red: 0x27, green: 0x7B, blue: 0x50, alpha: 0x24)
        }
        theme.colors.surfaceFloating = dark ? Color(red: 0x29, green: 0x2F, blue: 0x2D) : .white
        theme.colors.surfaceOverlay = theme.colors.surfaceRaised
        theme.colors.onBackground = theme.colors.onSurface
        theme.colors.borderStrong = theme.colors.border
        theme.colors.accentHover = dark ? Color(red: 0x7B, green: 0xC8, blue: 0x9F) : Color(red: 0x20, green: 0x6A, blue: 0x44)
        theme.colors.accentPressed = dark ? Color(red: 0x4C, green: 0x97, blue: 0x70) : Color(red: 0x1A, green: 0x59, blue: 0x39)
        theme.colors.onAccent = dark ? Color(red: 0x10, green: 0x24, blue: 0x18) : .white
        theme.colors.focusRing = theme.colors.accent
        theme.colors.stateLayerSelected = theme.colors.accentMuted
        theme.radius = RadiusScale(none: 0, sm: 3, md: 4, lg: 6, xl: 8, pill: 9999)
        theme.inputs.background = theme.colors.surfaceSunken
        theme.inputs.backgroundDisabled = theme.colors.surface
        theme.inputs.borderColor = theme.colors.border
        theme.inputs.borderHover = theme.colors.borderStrong
        theme.inputs.borderFocused = theme.colors.focusRing
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
    static let background = Color(red: 0x20, green: 0x24, blue: 0x25)
    static let gutter = Color(red: 0x1A, green: 0x1E, blue: 0x1F)
    static let header = Color(red: 0x24, green: 0x29, blue: 0x2A)
    static let selectedTab = Color(red: 0x2C, green: 0x34, blue: 0x31)
    static let foreground = Color(red: 0xDE, green: 0xE5, blue: 0xE1)
    static let muted = Color(red: 0x92, green: 0xA1, blue: 0x99)
    static let lineNumber = Color(red: 0x70, green: 0x80, blue: 0x77)
    static let accent = Color(red: 0x62, green: 0xB4, blue: 0x88)
}
