import EditorCore
import GuavaUI
import GuavaUIRuntime

enum EditorVisualTheme {
    static func make(dark: Bool, themeID: String = EditorThemeCatalog.defaultThemeID) -> Theme {
        EditorThemeCatalog.bundledTheme(id: themeID, dark: dark)
    }
}

/// Base colors for the editor's dark theme. Source panes resolve their colors
/// through the active semantic theme, including the light palette.
enum EditorCodePalette {
    static let background = Color(red: 0x17, green: 0x1C, blue: 0x1B)
    static let gutter = Color(red: 0x11, green: 0x15, blue: 0x15)
    static let header = Color(red: 0x1D, green: 0x23, blue: 0x21)
    static let selectedTab = Color(red: 0x33, green: 0x3A, blue: 0x37)
    static let foreground = Color(red: 0xEC, green: 0xEF, blue: 0xED)
    static let muted = Color(red: 0x8B, green: 0x94, blue: 0x8F)
    static let lineNumber = Color(red: 0x71, green: 0x79, blue: 0x76)
    static let accent = Color(red: 0x5F, green: 0xAF, blue: 0x82)
}
