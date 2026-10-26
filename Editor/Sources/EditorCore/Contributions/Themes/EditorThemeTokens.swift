public import CoveUICompose
public import CoveUIRuntime

public struct EditorThemeTokens: ThemeExtension {
    public internal(set) var assistant = Color(red: 0xF0, green: 0x7D, blue: 0x96)
    public internal(set) var syntax: [String: Color] = [:]
    public static let defaultValue = Self()
    public static let assistantColor = SemanticColorRef { $0.extensions[Self.self].assistant }
}

