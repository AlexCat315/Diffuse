public struct EditorPresentationState: Hashable, Codable, Sendable {
    public private(set) var themeMode: EditorThemeMode
    public private(set) var language: EditorLanguage
    public private(set) var revision: UInt64

    public init(themeMode: EditorThemeMode = .dark,
                language: EditorLanguage = .system,
                revision: UInt64 = 0) {
        self.themeMode = themeMode
        self.language = language
        self.revision = revision
        EditorLocalizationPreferences.language = language
    }

    @discardableResult
    public mutating func setThemeMode(_ mode: EditorThemeMode) -> Bool {
        themeMode = mode
        revision &+= 1
        return true
    }

    @discardableResult
    public mutating func setLanguage(_ nextLanguage: EditorLanguage) -> Bool {
        language = nextLanguage
        EditorLocalizationPreferences.language = nextLanguage
        revision &+= 1
        return true
    }

    public mutating func forceRefresh() {
        revision &+= 1
    }
}
