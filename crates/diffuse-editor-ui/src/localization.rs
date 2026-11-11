//! Translation of Editor/Sources/EditorUI/Localization.swift.
//!
//! Resolves a localized string from the EditorUI module bundle.

use cove_ui_compose::i18n::LocalizedStringKey;
use diffuse_editor_core::state::editor_state::EditorLocalizationPreferences;

use crate::resources_support::EditorAppResourceBundle;

/// Swift's `L(_ key: String) -> String`. The lookup mirrors the EditorCore
/// helper's `.lproj` search, against the EditorUI bundle.
pub fn localized(key: &str) -> String {
    let locales: Vec<String> = match EditorLocalizationPreferences::language().lproj_name() {
        Some(name) => vec![name.clone(), name.to_lowercase()],
        None => Vec::new(),
    };
    let bundle = EditorAppResourceBundle::bundle().root().to_path_buf();
    LocalizedStringKey::new(key, Some(bundle), None).resolved_for(&locales)
}
