import Foundation
import PluginRuntime
public import GuavaUICompose

extension EditorApplication {
    public var languageCatalog: LanguageCatalog { pluginSession.languages }
    public var aiProviderCatalog: AIProviderCatalog { pluginSession.providers }

    public var themeCatalog: ThemeCatalogSnapshot { pluginSession.contributions.themes.snapshot }

    public func resolvedTheme(dark: Bool) -> Theme {
        pluginSession.contributions.themes.theme(id: store.presentation.themeID, dark: dark)
    }

    var enabledPluginManifests: [String: GuavaPluginManifest] { pluginSession.manager.enabledManifests }
}
