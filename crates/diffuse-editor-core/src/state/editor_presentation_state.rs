//! `Editor/Sources/EditorCore/State/EditorPresentationState.swift`.

use serde::{Deserialize, Serialize};

use crate::contributions::themes::theme_catalog::EditorThemeCatalog;
use crate::localization::EditorLocalizationPreferences;
use crate::state::editor_state::{EditorLanguage, EditorThemeMode};

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorPresentationState {
    pub theme_mode: EditorThemeMode,
    pub language: EditorLanguage,
    #[serde(rename = "themeID")]
    pub theme_id: String,
    /// Bumped by every theme catalog change; not persisted.
    #[serde(skip)]
    pub theme_revision: u64,
    /// Bumped only by `force_refresh`. The presentation boundary keys its view
    /// tree on this, so it is the one signal that tears the tree down and
    /// re-measures everything.
    ///
    /// A theme or language change deliberately leaves it alone: both reach the
    /// view tree through the `ThemeEnvironment` composition local, which
    /// already invalidates the cached layers that resolve a token, so bumping
    /// this would only add a remount and a full layout pass to a repaint that
    /// was going to happen anyway.
    #[serde(skip)]
    pub refresh_revision: u64,
}

impl EditorPresentationState {
    /// Swift's `init(themeMode:language:refreshRevision:)` with its defaults.
    pub fn with_defaults() -> Self {
        Self::new(EditorThemeMode::Dark, EditorLanguage::System, 0)
    }

    /// Swift's memberwise initializer; it also publishes the language to the
    /// process-wide localization preference, exactly like Swift's initializer.
    pub fn new(
        theme_mode: EditorThemeMode,
        language: EditorLanguage,
        refresh_revision: u64,
    ) -> Self {
        EditorLocalizationPreferences::set_language(language);
        EditorPresentationState {
            theme_mode,
            language,
            theme_id: EditorThemeCatalog::DEFAULT_THEME_ID.to_string(),
            theme_revision: 0,
            refresh_revision,
        }
    }

    /// Returns `true` when the mode changed.
    pub fn set_theme_mode(&mut self, mode: EditorThemeMode) -> bool {
        if self.theme_mode == mode {
            return false;
        }
        self.theme_mode = mode;
        true
    }

    pub fn set_theme_id(&mut self, id: impl Into<String>) {
        self.theme_id = id.into();
    }

    pub fn refresh_theme_catalog(&mut self) {
        self.theme_revision = self.theme_revision.wrapping_add(1);
    }

    /// Returns `true` when the language changed.
    pub fn set_language(&mut self, next_language: EditorLanguage) -> bool {
        if self.language == next_language {
            return false;
        }
        self.language = next_language;
        EditorLocalizationPreferences::set_language(next_language);
        true
    }

    /// Escape hatch for callers that changed something the view tree cannot
    /// observe on its own: rebuild every node and re-measure the window.
    pub fn force_refresh(&mut self) {
        self.refresh_revision = self.refresh_revision.wrapping_add(1);
    }
}

impl Default for EditorPresentationState {
    fn default() -> Self {
        Self::with_defaults()
    }
}

impl<'de> Deserialize<'de> for EditorPresentationState {
    /// Swift's `init(from:)`: missing keys keep the presentation defaults and
    /// the decoded language is published to the localization preference.
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Raw {
            #[serde(default)]
            theme_mode: Option<EditorThemeMode>,
            #[serde(default)]
            language: Option<EditorLanguage>,
            #[serde(rename = "themeID", default)]
            theme_id: Option<String>,
        }
        let defaults = EditorPresentationState::with_defaults();
        let raw = Raw::deserialize(deserializer)?;
        let language = raw.language.unwrap_or(defaults.language);
        EditorLocalizationPreferences::set_language(language);
        Ok(EditorPresentationState {
            theme_mode: raw.theme_mode.unwrap_or(defaults.theme_mode),
            language,
            theme_id: raw.theme_id.unwrap_or(defaults.theme_id),
            theme_revision: 0,
            refresh_revision: 0,
        })
    }
}
