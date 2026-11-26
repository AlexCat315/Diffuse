//! `Editor/Sources/EditorCore/Application/Plugins/DocumentFormatting.swift`.
//!
//! Formatting a document through the language's format entry point.

use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;

use crate::application::editor_application::EditorApplication;

/// Why a format request produced nothing.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum DocumentFormattingError {
    #[error("No enabled plugin formats this language.")]
    Unavailable,
    #[error("The document exceeds the 64 KiB formatting limit.")]
    InputTooLarge,
    #[error("The formatter returned an unexpected result.")]
    UnexpectedResult,
    #[error("{0}")]
    Runtime(String),
}

impl EditorApplication {
    /// Runs the language's format entry point when its package is mounted.
    /// `None` means a language without a contribution or a disabled package:
    /// the document stays unchanged.
    pub fn format_document(
        &self,
        language_id: &str,
        text: &str,
    ) -> Result<Option<String>, DocumentFormattingError> {
        let Some(format) = self.language_catalog().format(Some(language_id)) else {
            return Ok(None);
        };
        if !self
            .enabled_plugin_manifests()
            .contains_key(&format.plugin_id)
        {
            return Ok(None);
        }
        if text.len() > 64 * 1_024 {
            return Err(DocumentFormattingError::InputTooLarge);
        }
        let event = format!("onLanguage:{language_id}");
        let (binding, client) = self
            .plugin_session
            .runtime
            .resolve(&format.plugin_id, &event)
            .map_err(|error| DocumentFormattingError::Runtime(error.to_string()))?;
        if !self
            .plugin_session
            .manager
            .active_bindings()
            .contains_key(&format.plugin_id)
        {
            return Err(DocumentFormattingError::Unavailable);
        }
        if self
            .plugin_session
            .hosts
            .existing(&format.plugin_id)
            .is_none()
        {
            return Ok(None);
        }
        let input = serde_json::to_vec(&serde_json::json!({ "text": text }))
            .map_err(|error| DocumentFormattingError::Runtime(error.to_string()))?;
        let capability_id = format!("{}.{}", format.plugin_id, format.entry_point);
        let result = client
            .prepare_capability(&binding, &capability_id, &input, None)
            .map_err(|error| DocumentFormattingError::Runtime(error.to_string()))?;
        // Read results cross the host as JSON; the capability returns the
        // formatted text as a JSON string.
        let PluginPreparedCapabilityResult::Read(data) = result else {
            return Err(DocumentFormattingError::UnexpectedResult);
        };
        serde_json::from_slice::<String>(&data)
            .map(Some)
            .map_err(|_| DocumentFormattingError::UnexpectedResult)
    }
}
