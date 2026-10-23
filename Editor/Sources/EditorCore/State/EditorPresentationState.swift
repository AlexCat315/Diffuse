public struct EditorPresentationState: Hashable, Codable, Sendable {
    public private(set) var themeMode: EditorThemeMode
    public private(set) var language: EditorLanguage
    public private(set) var themeID: String = EditorThemeCatalog.defaultThemeID
    public private(set) var themeRevision: UInt64 = 0
    /// Bumped only by `forceRefresh`. The presentation boundary keys its view
    /// tree on this, so it is the one signal that tears the tree down and
    /// re-measures everything.
    ///
    /// A theme or language change deliberately leaves it alone: both reach the
    /// view tree through the `ThemeEnvironment` composition local, which
    /// already invalidates the cached layers that resolve a token, so bumping
    /// this would only add a remount and a full layout pass to a repaint that
    /// was going to happen anyway.
    public private(set) var refreshRevision: UInt64 = 0

    private enum CodingKeys: String, CodingKey { case themeMode, language, themeID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        themeMode = try values.decodeIfPresent(EditorThemeMode.self, forKey: .themeMode) ?? .dark
        language = try values.decodeIfPresent(EditorLanguage.self, forKey: .language) ?? .system
        themeID = try values.decodeIfPresent(String.self, forKey: .themeID) ?? themeID
        EditorLocalizationPreferences.language = language
    }

    public init(
        themeMode: EditorThemeMode = .dark,
        language: EditorLanguage = .system,
        refreshRevision: UInt64 = 0
    ) {
        self.themeMode = themeMode
        self.language = language
        self.refreshRevision = refreshRevision
        EditorLocalizationPreferences.language = language
    }

    @discardableResult
    public mutating func setThemeMode(_ mode: EditorThemeMode) -> Bool {
        guard themeMode != mode else { return false }
        themeMode = mode
        return true
    }

    public mutating func setThemeID(_ id: String) {
        themeID = id
    }

    public mutating func refreshThemeCatalog() {
        themeRevision &+= 1
    }

    @discardableResult
    public mutating func setLanguage(_ nextLanguage: EditorLanguage) -> Bool {
        guard language != nextLanguage else { return false }
        language = nextLanguage
        EditorLocalizationPreferences.language = nextLanguage
        return true
    }

    /// Escape hatch for callers that changed something the view tree cannot
    /// observe on its own: rebuild every node and re-measure the window.
    public mutating func forceRefresh() {
        refreshRevision &+= 1
    }
}
