//! `Editor/Sources/EditorCore/Application/Plugins/Catalogs.swift`.

use std::collections::BTreeMap;

use cove_ui_compose::theme::Theme;
use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;

use crate::application::editor_application::EditorApplication;
use crate::contributions::agents::AgentCatalog;
use crate::contributions::ai_providers::AIProviderCatalog;
use crate::contributions::languages::LanguageCatalog;
use crate::contributions::themes::theme_catalog::ThemeCatalogSnapshot;

impl EditorApplication {
    pub fn language_catalog(&self) -> LanguageCatalog {
        self.plugin_session.state().languages.clone()
    }

    pub fn ai_provider_catalog(&self) -> AIProviderCatalog {
        self.plugin_session.state().providers.clone()
    }

    /// Enabled agents. Empty means this editor has no assistant surface.
    pub fn agent_catalog(&self) -> AgentCatalog {
        self.plugin_session.state().agents.clone()
    }

    pub fn is_agent_enabled(&self) -> bool {
        !self.plugin_session.state().agents.is_empty()
    }

    pub fn theme_catalog(&self) -> ThemeCatalogSnapshot {
        self.plugin_session.contributions.themes.snapshot()
    }

    pub fn resolved_theme(&self, dark: bool) -> Theme {
        self.plugin_session
            .contributions
            .themes
            .theme(&self.store.presentation().theme_id, dark)
    }

    pub fn enabled_plugin_manifests(&self) -> BTreeMap<String, CovePluginManifest> {
        self.plugin_session.manager.enabled_manifests()
    }
}
