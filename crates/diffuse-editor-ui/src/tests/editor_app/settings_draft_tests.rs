//! Ported from the draft cases in
//! `Editor/Tests/EditorWorkbenchTests/SettingsWorkflowTests.swift`.

use std::collections::BTreeMap;

use cove_ui_compose::primitives::text::TextBuffer;
use diffuse_editor_core::ai::chat::editor_ai_settings::EditorAISettings;
use diffuse_editor_core::contributions::ai_providers::{AIProviderCatalog, AIProviderDescriptor};

use crate::settings::assistant::draft::EditorAISettingsDraft;

fn provider(id: &str, default_model: &str) -> AIProviderDescriptor {
    AIProviderDescriptor {
        plugin_id: "fixture.providers".to_string(),
        id: id.to_string(),
        title: id.to_string(),
        api_format: "openai".to_string(),
        base_url: None,
        default_model: default_model.to_string(),
        models: Vec::new(),
        auth_fields: Vec::new(),
    }
}

fn catalog() -> AIProviderCatalog {
    AIProviderCatalog {
        providers: vec![
            provider("alpha", "alpha-default"),
            provider("beta", "beta-default"),
        ],
    }
}

/// A disabled provider starts with a blank model.
#[test]
fn disabled_provider_starts_blank() {
    let draft = EditorAISettingsDraft::new(&EditorAISettings::new("", "ignored", "agent", false));
    assert_eq!(draft.model.string_value(), "");
    assert_eq!(draft.provider_id(), "");
    assert_eq!(draft.agent_id, "agent");

    let enabled =
        EditorAISettingsDraft::new(&EditorAISettings::new("alpha", "alpha-default", "", true));
    assert_eq!(enabled.model.string_value(), "alpha-default");
    assert!(enabled.auto_approve);
}

/// Selecting a provider adopts its default model unless the user typed one.
#[test]
fn provider_selection_updates_default_model() {
    let catalog = catalog();
    let mut draft =
        EditorAISettingsDraft::new(&EditorAISettings::new("alpha", "alpha-default", "", false));
    draft
        .credentials
        .insert("key".to_string(), TextBuffer::from("secret"));

    draft.select(catalog.provider("alpha"), &catalog);
    assert_eq!(draft.model.string_value(), "alpha-default");
    assert_eq!(draft.credentials.len(), 1);

    draft.select(catalog.provider("beta"), &catalog);
    assert_eq!(draft.provider_id(), "beta");
    assert_eq!(draft.model.string_value(), "beta-default");
    assert!(draft.credentials.is_empty());

    let mut custom =
        EditorAISettingsDraft::new(&EditorAISettings::new("alpha", "custom", "", false));
    custom.select(catalog.provider("beta"), &catalog);
    assert_eq!(custom.model.string_value(), "custom");

    custom.select(None, &catalog);
    assert_eq!(custom.provider_id(), "");
    assert_eq!(custom.model.string_value(), "custom");
}

/// Entered credentials are trimmed and blank fields drop out.
#[test]
fn entered_credentials_trim_and_drop_blanks() {
    let mut draft = EditorAISettingsDraft::new(&EditorAISettings::new("", "", "", false));
    draft
        .credentials
        .insert("key".to_string(), TextBuffer::from("  secret \n"));
    draft
        .credentials
        .insert("blank".to_string(), TextBuffer::from("   "));
    let entered = draft.entered_credentials();
    assert_eq!(
        entered,
        BTreeMap::from([("key".to_string(), "secret".to_string())])
    );
}
