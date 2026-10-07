import GuavaUICompose
import GuavaUIRuntime

/// Editor chrome has its own restrained palette and density. Generic GuavaUI
/// apps keep their defaults; all editor panes share this single token source.
enum EditorVisualTheme {
    static func make(dark: Bool) -> Theme {
        var theme = dark ? Theme.defaultDark : Theme.defaultLight
        if dark {
            theme.colors.background = Color(red: 0x11, green: 0x15, blue: 0x15)
            theme.colors.surface = EditorCodePalette.background
            theme.colors.surfaceVariant = EditorCodePalette.selectedTab
            theme.colors.surfaceSunken = EditorCodePalette.gutter
            theme.colors.surfaceRaised = EditorCodePalette.header
            theme.colors.onSurface = EditorCodePalette.foreground
            theme.colors.onSurfaceVariant = Color(red: 0xA6, green: 0xAE, blue: 0xAA)
            theme.colors.onSurfaceMuted = EditorCodePalette.muted
            theme.colors.border = Color.white.multipliedAlpha(0.06)
            theme.colors.divider = Color.white.multipliedAlpha(0.06)
            theme.colors.accent = EditorCodePalette.accent
            theme.colors.accentMuted = EditorCodePalette.accent.multipliedAlpha(0.12)
            theme.colors.selection = EditorCodePalette.selectedTab
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
        theme.colors.surfaceFloating = dark ? Color(red: 24, green: 29, blue: 28, alpha: 240) : .white
        theme.colors.surfaceOverlay = theme.colors.surfaceRaised
        theme.colors.onBackground = theme.colors.onSurface
        theme.colors.borderStrong = dark ? Color.white.multipliedAlpha(0.10) : theme.colors.border
        theme.colors.accentHover = dark ? Color(red: 0x69, green: 0xB9, blue: 0x8B) : Color(red: 0x20, green: 0x6A, blue: 0x44)
        theme.colors.accentPressed = dark ? Color(red: 0x4C, green: 0x97, blue: 0x70) : Color(red: 0x1A, green: 0x59, blue: 0x39)
        theme.colors.onAccent = dark ? Color(red: 0x10, green: 0x24, blue: 0x18) : .white
        theme.colors.focusRing = theme.colors.accent
        theme.colors.stateLayerSelected = theme.colors.surfaceVariant
        if dark {
            theme.colors.stateLayerHover = Color.white.multipliedAlpha(0.055)
            theme.colors.stateLayerPressed = Color.white.multipliedAlpha(0.085)
            theme.colors.success = EditorCodePalette.accent
            theme.textEmphasis = TextEmphasis {
                $0.placeholder = EditorCodePalette.muted
                $0.disabled = Color(red: 0x50, green: 0x56, blue: 0x53)
            }
            theme.elevation.low = Shadow(color: Color.black.multipliedAlpha(0.25), offsetX: 0, offsetY: 1, blur: 2)
        }
        theme.motion.fast = .milliseconds(120)
        theme.motion.standard = .milliseconds(220)
        theme.motion.slow = .milliseconds(280)
        theme.motion.standardEasing = .emphasized
        theme.radius = RadiusScale(none: 0, sm: 4, md: 4, lg: 6, xl: 6, pill: 9999)
        theme.inputs.background = theme.colors.surfaceSunken
        theme.inputs.backgroundDisabled = theme.colors.surface
        theme.inputs.borderColor = theme.colors.border
        theme.inputs.borderHover = dark ? Color.white.multipliedAlpha(0.14) : theme.colors.borderStrong
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
    static let background = Color(red: 0x17, green: 0x1C, blue: 0x1B)
    static let gutter = Color(red: 0x11, green: 0x15, blue: 0x15)
    static let header = Color(red: 0x1D, green: 0x23, blue: 0x21)
    static let selectedTab = Color(red: 0x25, green: 0x2D, blue: 0x2A)
    static let foreground = Color(red: 0xE6, green: 0xEA, blue: 0xE8)
    static let muted = Color(red: 0x71, green: 0x79, blue: 0x76)
    static let lineNumber = Color(red: 0x71, green: 0x79, blue: 0x76)
    static let accent = Color(red: 0x5F, green: 0xAF, blue: 0x82)
}
