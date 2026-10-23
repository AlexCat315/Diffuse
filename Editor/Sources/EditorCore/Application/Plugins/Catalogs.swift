import Foundation
import PluginRuntime
public import GuavaUICompose

extension EditorApplication {
    public var languageCatalog: LanguageCatalog { pluginSession.languages }
    public var aiProviderCatalog: AIProviderCatalog { pluginSession.providers }
    /// Enabled agents. Empty means this editor has no assistant surface.
    public var agentCatalog: AgentCatalog { pluginSession.agents }
    public var isAgentEnabled: Bool { !pluginSession.agents.isEmpty }

    public var themeCatalog: ThemeCatalogSnapshot { pluginSession.contributions.themes.snapshot }

    public func resolvedTheme(dark: Bool) -> Theme {
        pluginSession.contributions.themes.theme(id: store.presentation.themeID, dark: dark)
    }

    var enabledPluginManifests: [String: GuavaPluginManifest] { pluginSession.manager.enabledManifests }
}
