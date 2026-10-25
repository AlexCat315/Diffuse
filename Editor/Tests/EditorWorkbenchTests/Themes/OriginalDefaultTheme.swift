@testable import EditorCore
import GuavaUI
import GuavaUIRuntime

/// Frozen pre-plugin behavior used to verify the resource migration.
enum OriginalDefaultTheme {
    static func make(dark: Bool) -> Theme {
        var theme = dark ? Theme.defaultDark : Theme.defaultLight
        basePalette(&theme, dark: dark)
        interactionPalette(&theme, dark: dark)
        metrics(&theme)
        decorations(&theme, dark: dark)
        inputs(&theme, dark: dark)
        return theme
    }

    private static func basePalette(_ theme: inout Theme, dark: Bool) {
        if dark {
            // Three layers, never separated by rules: the canvas, rounded panes
            // (surface) on it, and cards (surfaceRaised) inside panes. Charcoal,
            // not black: each layer is one clear step lighter, so the window
            // never reads as one dark mass.
            theme.colors.background = Color(red: 0x14, green: 0x17, blue: 0x16)
            theme.colors.surface = Color(red: 0x1D, green: 0x21, blue: 0x20)
            theme.colors.surfaceVariant = OriginalCodePalette.selectedTab
            theme.colors.surfaceSunken = Color(red: 0x17, green: 0x1B, blue: 0x1A)
            // Cards inside a pane: one step above the pane, never outlined.
            theme.colors.surfaceRaised = Color(red: 0x27, green: 0x2C, blue: 0x2A)
            theme.colors.onSurface = OriginalCodePalette.foreground
            theme.colors.onSurfaceVariant = Color(red: 0xB6, green: 0xBE, blue: 0xBA)
            theme.colors.onSurfaceMuted = OriginalCodePalette.muted
            theme.colors.border = Color.white.multipliedAlpha(0.08)
            theme.colors.divider = Color.white.multipliedAlpha(0.08)
            theme.colors.accent = OriginalCodePalette.accent
            theme.colors.accentMuted = OriginalCodePalette.accent.multipliedAlpha(0.12)
            theme.colors.selection = OriginalCodePalette.accent.multipliedAlpha(0.16)
        } else {
            theme.colors.background = Color(red: 0xE3, green: 0xE8, blue: 0xE5)
            theme.colors.surface = Color(red: 0xFB, green: 0xFC, blue: 0xFB)
            theme.colors.surfaceVariant = Color(red: 0xE9, green: 0xED, blue: 0xEA)
            theme.colors.surfaceSunken = .white
            theme.colors.surfaceRaised = Color(red: 0xF1, green: 0xF4, blue: 0xF2)
            theme.colors.onSurface = Color(red: 0x25, green: 0x30, blue: 0x2B)
            theme.colors.onSurfaceVariant = Color(red: 0x57, green: 0x65, blue: 0x5E)
            theme.colors.onSurfaceMuted = Color(red: 0x6B, green: 0x7A, blue: 0x71)
            theme.colors.border = Color(red: 0xD2, green: 0xDB, blue: 0xD5)
            theme.colors.divider = Color(red: 0xD5, green: 0xDD, blue: 0xD8, alpha: 0xAA)
            theme.colors.accent = Color(red: 0x27, green: 0x7B, blue: 0x50)
            theme.colors.accentMuted = Color(red: 0x27, green: 0x7B, blue: 0x50, alpha: 0x16)
            theme.colors.selection = Color(red: 0x27, green: 0x7B, blue: 0x50, alpha: 0x24)
        }
    }

    private static func interactionPalette(_ theme: inout Theme, dark: Bool) {
        theme.colors.surfaceFloating = dark ? Color(red: 0x2E, green: 0x34, blue: 0x31, alpha: 245) : .white
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
            theme.colors.success = OriginalCodePalette.accent
        }
    }

    private static func metrics(_ theme: inout Theme) {
        theme.typography.body = .init(font: .system(size: 12), lineHeight: 18)
        theme.typography.bodyStrong = .init(font: .system(size: 12, weight: .semibold), lineHeight: 18)
        theme.typography.label = .init(font: .system(size: 12, weight: .medium), lineHeight: 16)
        theme.typography.caption = .init(font: .system(size: 11), lineHeight: 16)
        theme.typography.mono = .init(font: .monospaced(size: 11), lineHeight: 17)
        theme.radius.sm = 5
        theme.radius.md = 7
        theme.radius.lg = 10
        theme.motion.fast = .milliseconds(120)
        theme.motion.standard = .milliseconds(220)
        theme.motion.slow = .milliseconds(280)
        theme.motion.standardEasing = .emphasized
    }

    private static func decorations(_ theme: inout Theme, dark: Bool) {
        theme.extensions[EditorThemeTokens.self].assistant = dark
            ? Color(red: 0xF0, green: 0x7D, blue: 0x96)
            : Color(red: 0xC8, green: 0x43, blue: 0x5F)
        if dark {
            theme.textEmphasis = TextEmphasis {
                $0.placeholder = OriginalCodePalette.muted
                $0.disabled = Color(red: 0x50, green: 0x56, blue: 0x53)
            }
            theme.elevation.low = SurfaceShadow(color: Color.black.multipliedAlpha(0.25), offsetX: 0, offsetY: 1, blur: 2)
        }
    }

    private static func inputs(_ theme: inout Theme, dark: Bool) {
        theme.inputs.background = theme.colors.surfaceSunken
        theme.inputs.radius = theme.radius.sm
        theme.inputs.backgroundDisabled = theme.colors.surface
        theme.inputs.borderColor = theme.colors.border
        theme.inputs.borderHover = dark ? Color.white.multipliedAlpha(0.14) : theme.colors.borderStrong
        theme.inputs.borderFocused = theme.colors.focusRing
        theme.inputs.borderDisabled = theme.colors.divider
        theme.inputs.dividerColor = theme.colors.divider
        theme.inputs.addonBackground = theme.colors.surface
        theme.inputs.focusRingWidth = 1.5
    }
}

/// Base colors for the editor's dark theme. Source panes resolve their colors
/// through the active semantic theme, including the light palette.
enum OriginalCodePalette {
    static let background = Color(red: 0x17, green: 0x1C, blue: 0x1B)
    static let gutter = Color(red: 0x11, green: 0x15, blue: 0x15)
    static let header = Color(red: 0x1D, green: 0x23, blue: 0x21)
    static let selectedTab = Color(red: 0x33, green: 0x3A, blue: 0x37)
    static let foreground = Color(red: 0xEC, green: 0xEF, blue: 0xED)
    static let muted = Color(red: 0x8B, green: 0x94, blue: 0x8F)
    static let lineNumber = Color(red: 0x71, green: 0x79, blue: 0x76)
    static let accent = Color(red: 0x5F, green: 0xAF, blue: 0x82)
}
