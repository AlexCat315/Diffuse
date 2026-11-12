//! `Editor/Sources/EditorCore/Localization.swift`.
//!
//! Strings resolve through the EditorCore resource bundle's `.lproj`
//! directories, the same lookup Cove's `LocalizedStringKey` performs for
//! Compose. The Swift file's `L(_:)` helper is [`localized`].

use std::sync::atomic::{AtomicU8, Ordering};

use cove_ui_compose::i18n::LocalizedStringKey;

use crate::editor_core_resource_bundle::EditorCoreResourceBundle;
use crate::state::editor_state::EditorLanguage;

/// The language the editor resolves its strings in.
pub struct EditorLocalizationPreferences;

static LANGUAGE: AtomicU8 = AtomicU8::new(0);

impl EditorLocalizationPreferences {
    pub fn language() -> EditorLanguage {
        match LANGUAGE.load(Ordering::SeqCst) {
            1 => EditorLanguage::English,
            2 => EditorLanguage::SimplifiedChinese,
            _ => EditorLanguage::System,
        }
    }

    pub fn set_language(language: EditorLanguage) {
        let value = match language {
            EditorLanguage::System => 0,
            EditorLanguage::English => 1,
            EditorLanguage::SimplifiedChinese => 2,
        };
        LANGUAGE.store(value, Ordering::SeqCst);
    }
}

/// Swift's `L(_ key: String) -> String`.
pub(crate) fn localized(key: &str) -> String {
    let locales: Vec<String> = match EditorLocalizationPreferences::language().lproj_name() {
        Some(name) => vec![name.clone(), name.to_lowercase()],
        None => Vec::new(),
    };
    let Some(bundle) = EditorCoreResourceBundle::bundle_if_available() else {
        return key.to_string();
    };
    LocalizedStringKey::new(key, Some(bundle.root().to_path_buf()), None).resolved_for(&locales)
}
