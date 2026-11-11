//! `Editor/Sources/EditorCore/State/Assistant/EditorAssistantState.swift`.

use serde::{Deserialize, Serialize};

use diffuse_intent::invocation::capability_invocation::ConfirmationRequestBatch;

use crate::ai::chat::ai_chat_message::AIChatMessage;
use crate::ai::chat::editor_agent_task_service::EditorAgentTask;
use crate::ai::chat::editor_ai_settings::{EditorAISettings, EditorCapabilitySettings};
use crate::ai::plugins::editor_plugin_management_state::EditorPluginManagementState;
use crate::state::workspace::content::EditorContent;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorAssistantState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_confirmation_request: Option<ConfirmationRequestBatch>,
    /// Session settings; the AI settings are read from their own store.
    #[serde(skip)]
    pub ai_settings: EditorAISettings,
    pub capability_settings: EditorCapabilitySettings,
    #[serde(skip)]
    pub plugin_management: EditorPluginManagementState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ai_status_message: Option<String>,
    pub ai_warnings: Vec<String>,
    /// Task sessions are transient and are never restored as running after launch.
    #[serde(skip)]
    pub agent_tasks: Vec<EditorAgentTask>,
    #[serde(skip)]
    pub chat_messages: Vec<AIChatMessage>,
    /// The content the agent last worked on in this conversation; it decides what the
    /// agent view shows beside the thread. Transient, like the conversation.
    #[serde(skip)]
    pub agent_canvas: Option<EditorContent>,
}

impl EditorAssistantState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorAssistantState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorAssistantState)) -> Self {
        let mut state = EditorAssistantState::default();
        configure(&mut state);
        state
    }
}

impl Default for EditorAssistantState {
    fn default() -> Self {
        EditorAssistantState {
            pending_confirmation_request: None,
            ai_settings: EditorAISettings::with_defaults(),
            capability_settings: EditorCapabilitySettings::with_defaults(),
            plugin_management: EditorPluginManagementState::idle(),
            ai_status_message: None,
            ai_warnings: Vec::new(),
            agent_tasks: Vec::new(),
            chat_messages: Vec::new(),
            agent_canvas: None,
        }
    }
}
