public import GuavaUICompose
public import GuavaUIRuntime

public struct EditorThemeTokens: ThemeExtension {
    public internal(set) var harness = Color(red: 0xF0, green: 0x7D, blue: 0x96)
    public internal(set) var syntax: [String: Color] = [:]
    public static let defaultValue = Self()
    public static let harnessColor = SemanticColorRef { $0.extensions[Self.self].harness }
}

