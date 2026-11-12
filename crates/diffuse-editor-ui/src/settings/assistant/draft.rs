//! `Editor/Sources/EditorUI/Settings/Assistant/Draft.swift`.

use std::collections::BTreeMap;

use cove_ui_compose::primitives::text::TextBuffer;
use diffuse_editor_core::ai::chat::editor_ai_settings::EditorAISettings;
use diffuse_editor_core::contributions::ai_providers::{AIProviderCatalog, AIProviderDescriptor};

#[derive(Clone, Debug, PartialEq)]
pub struct EditorAISettingsDraft {
    provider_id: String,
    pub model: TextBuffer,
    pub agent_id: String,
    /// Values typed for the provider's auth fields, by field ID; blank keeps the
    /// stored value.
    pub credentials: BTreeMap<String, TextBuffer>,
    pub auto_approve: bool,
}

impl EditorAISettingsDraft {
    pub fn new(settings: &EditorAISettings) -> Self {
        EditorAISettingsDraft {
            provider_id: settings.provider_id.clone(),
            // A model has no meaning while disabled; start blank so selecting a
            // provider reliably adopts that provider's default model.
            model: TextBuffer::from(if settings.is_enabled() {
                settings.model.clone()
            } else {
                String::new()
            }),
            agent_id: settings.agent_id.clone(),
            credentials: BTreeMap::new(),
            auto_approve: settings.auto_approve,
        }
    }

    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }

    pub fn select(
        &mut self,
        next_provider: Option<&AIProviderDescriptor>,
        catalog: &AIProviderCatalog,
    ) {
        let next_id = next_provider
            .map(|provider| provider.id.as_str())
            .unwrap_or("");
        if self.provider_id == next_id {
            return;
        }
        let previous_default_model = catalog
            .provider(&self.provider_id)
            .map(|provider| provider.default_model.as_str())
            .unwrap_or("");
        if self.model.is_empty() || self.model.string_value() == previous_default_model {
            self.model = TextBuffer::from(
                next_provider
                    .map(|provider| provider.default_model.clone())
                    .unwrap_or_default(),
            );
        }
        // Never carry an uncommitted secret across providers: otherwise a key
        // typed for one service could silently be stored under another.
        self.credentials.clear();
        self.provider_id = next_id.to_string();
    }

    /// Entered values, trimmed; blank fields are left out.
    pub fn entered_credentials(&self) -> BTreeMap<String, String> {
        self.credentials
            .iter()
            .map(|(key, value)| (key.clone(), value.string_value().trim().to_string()))
            .filter(|(_, value)| !value.is_empty())
            .collect()
    }
}
