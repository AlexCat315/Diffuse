//! Ported from `Engine/Sources/AIRuntime/Session/ConversationTurn.swift`.

use diffuse_capability::support::swift_date::SwiftDate;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// One message in the conversation the session keeps for the model.
#[derive(Clone, Debug, PartialEq)]
pub enum ConversationTurnKind {
    UserText(String),
    AssistantToolCall {
        tool_use_id: String,
        name: String,
        input_json: String,
    },
    ToolResult {
        tool_use_id: String,
        content: String,
    },
}

/// The payload of a `userText` case: Swift's synthesized `Codable` names the
/// unlabeled associated value `_0`.
#[derive(Serialize, Deserialize)]
struct UserTextPayload {
    #[serde(rename = "_0")]
    value: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssistantToolCallPayload {
    #[serde(rename = "toolUseID")]
    tool_use_id: String,
    name: String,
    #[serde(rename = "inputJSON")]
    input_json: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ToolResultPayload {
    #[serde(rename = "toolUseID")]
    tool_use_id: String,
    content: String,
}

/// Mirrors the wire shape Swift's compiler synthesizes for an enum with
/// associated values: `{"caseName": {payload}}`.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ConversationTurnKindWire {
    UserText(UserTextPayload),
    AssistantToolCall(AssistantToolCallPayload),
    ToolResult(ToolResultPayload),
}

impl Serialize for ConversationTurnKind {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            ConversationTurnKind::UserText(text) => {
                ConversationTurnKindWire::UserText(UserTextPayload {
                    value: text.clone(),
                })
                .serialize(serializer)
            }
            ConversationTurnKind::AssistantToolCall {
                tool_use_id,
                name,
                input_json,
            } => ConversationTurnKindWire::AssistantToolCall(AssistantToolCallPayload {
                tool_use_id: tool_use_id.clone(),
                name: name.clone(),
                input_json: input_json.clone(),
            })
            .serialize(serializer),
            ConversationTurnKind::ToolResult {
                tool_use_id,
                content,
            } => ConversationTurnKindWire::ToolResult(ToolResultPayload {
                tool_use_id: tool_use_id.clone(),
                content: content.clone(),
            })
            .serialize(serializer),
        }
    }
}

impl<'de> Deserialize<'de> for ConversationTurnKind {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match ConversationTurnKindWire::deserialize(deserializer)? {
            ConversationTurnKindWire::UserText(payload) => {
                ConversationTurnKind::UserText(payload.value)
            }
            ConversationTurnKindWire::AssistantToolCall(payload) => {
                ConversationTurnKind::AssistantToolCall {
                    tool_use_id: payload.tool_use_id,
                    name: payload.name,
                    input_json: payload.input_json,
                }
            }
            ConversationTurnKindWire::ToolResult(payload) => ConversationTurnKind::ToolResult {
                tool_use_id: payload.tool_use_id,
                content: payload.content,
            },
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationTurn {
    pub kind: ConversationTurnKind,
    pub timestamp: SwiftDate,
    #[serde(rename = "proposalID", skip_serializing_if = "Option::is_none")]
    pub proposal_id: Option<String>,
}

impl ConversationTurn {
    pub fn new(kind: ConversationTurnKind) -> Self {
        Self {
            kind,
            timestamp: SwiftDate::now(),
            proposal_id: None,
        }
    }

    pub fn with_proposal_id(mut self, proposal_id: Option<String>) -> Self {
        self.proposal_id = proposal_id;
        self
    }
}
