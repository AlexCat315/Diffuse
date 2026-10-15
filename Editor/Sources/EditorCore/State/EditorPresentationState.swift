public struct EditorPresentationState: Hashable, Codable, Sendable {
    public private(set) var themeMode: EditorThemeMode
    public private(set) var language: EditorLanguage
    /// Bumped only by `forceRefresh`. The presentation boundary keys its view
    /// tree on this, so it is the one signal that tears the tree down and
    /// re-measures everything.
    ///
    /// A theme or language change deliberately leaves it alone: both reach the
    /// view tree through the `ThemeEnvironment` composition local, which
    /// already invalidates the cached layers that resolve a token, so bumping
    /// this would only add a remount and a full layout pass to a repaint that
    /// was going to happen anyway.
    public private(set) var refreshRevision: UInt64

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