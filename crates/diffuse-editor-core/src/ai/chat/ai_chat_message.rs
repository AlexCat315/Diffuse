//! `Editor/Sources/EditorCore/AI/Chat/AIChatMessage.swift` — one message in the
//! assistant thread.

use diffuse_kernel::codable::new_uuid;

/// Who wrote the message.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AIChatMessageRole {
    User,
    Assistant,
}

/// The assistant's progress for one reply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AIChatAssistantState {
    Thinking,
    Streaming(String),
    Replied(String),
    PendingConfirmation { summary: String },
    Applied { summary: String },
    Discarded,
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AIChatMessage {
    pub id: String,
    pub role: AIChatMessageRole,
    pub text: String,
    pub assistant_state: Option<AIChatAssistantState>,
}

impl AIChatMessage {
    pub fn new(
        id: impl Into<String>,
        role: AIChatMessageRole,
        text: impl Into<String>,
        assistant_state: Option<AIChatAssistantState>,
    ) -> Self {
        AIChatMessage {
            id: id.into(),
            role,
            text: text.into(),
            assistant_state,
        }
    }

    /// Swift's `id: String = UUID().uuidString` default.
    pub fn with_default_id(
        role: AIChatMessageRole,
        text: impl Into<String>,
        assistant_state: Option<AIChatAssistantState>,
    ) -> Self {
        Self::new(new_uuid(), role, text, assistant_state)
    }
}
