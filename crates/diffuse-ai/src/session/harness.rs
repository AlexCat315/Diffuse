//! Ported from `Engine/Sources/AIRuntime/Session/Harness.swift`.

use std::error::Error;
use std::sync::Arc;

use diffuse_plugin::contract::plugin_json::PluginJSON;
use serde::de::Error as _;
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Drives a turn in place of the built-in loop. Given what just happened, it
/// says what the session does next; the session alone calls the model and runs
/// tools, so tool policies, drafts and approvals still apply.
///
/// Swift declared this `async throws`; there is no async runtime here, so the
/// closure runs to completion on the calling thread and reports failure through
/// the boxed error.
pub type SessionHarness = Arc<
    dyn Fn(SessionHarnessTurn) -> Result<SessionHarnessStep, Box<dyn Error + Send + Sync>>
        + Send
        + Sync,
>;

/// What a harness sees at each step.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionHarnessTurn {
    pub step: i64,
    pub state: Option<PluginJSON>,
    pub request: SessionHarnessTurnRequest,
    pub tools: Vec<SessionHarnessTurnTool>,
    pub observation: Option<SessionHarnessTurnObservation>,
}

impl SessionHarnessTurn {
    pub fn new(
        step: i64,
        state: Option<PluginJSON>,
        request: SessionHarnessTurnRequest,
        tools: Vec<SessionHarnessTurnTool>,
        observation: Option<SessionHarnessTurnObservation>,
    ) -> Self {
        Self {
            step,
            state,
            request,
            tools,
            observation,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SessionHarnessTurnRequest {
    pub text: String,
    pub locale: String,
}

impl SessionHarnessTurnRequest {
    pub fn new(text: String, locale: String) -> Self {
        Self { text, locale }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHarnessTurnTool {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema", skip_serializing_if = "Option::is_none")]
    pub input_schema: Option<PluginJSON>,
}

impl SessionHarnessTurnTool {
    pub fn new(name: String, description: String) -> Self {
        Self {
            name,
            description,
            input_schema: None,
        }
    }

    pub fn with_input_schema(mut self, input_schema: Option<PluginJSON>) -> Self {
        self.input_schema = input_schema;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHarnessTurnCall {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<PluginJSON>,
}

impl SessionHarnessTurnCall {
    pub fn new(name: String) -> Self {
        Self {
            id: None,
            name,
            arguments: None,
        }
    }

    pub fn with_id(mut self, id: Option<String>) -> Self {
        self.id = id;
        self
    }

    pub fn with_arguments(mut self, arguments: Option<PluginJSON>) -> Self {
        self.arguments = arguments;
        self
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum SessionHarnessTurnObservation {
    /// The tool the model asked for; not run yet.
    Model(SessionHarnessTurnCall),
    /// A tool the session ran, with its result.
    Tool(SessionHarnessTurnCall, PluginJSON),
    Failure(String),
}

impl Serialize for SessionHarnessTurnObservation {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(None)?;
        match self {
            SessionHarnessTurnObservation::Model(call) => {
                map.serialize_entry("type", "model")?;
                map.serialize_entry("call", call)?;
            }
            SessionHarnessTurnObservation::Tool(call, result) => {
                map.serialize_entry("type", "tool")?;
                map.serialize_entry("call", call)?;
                map.serialize_entry("result", result)?;
            }
            SessionHarnessTurnObservation::Failure(message) => {
                map.serialize_entry("type", "failure")?;
                map.serialize_entry("message", message)?;
            }
        }
        map.end()
    }
}

impl Serialize for SessionHarnessTurn {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut container = serializer.serialize_map(None)?;
        container.serialize_entry("step", &self.step)?;
        if let Some(state) = &self.state {
            container.serialize_entry("state", state)?;
        }
        container.serialize_entry("request", &self.request)?;
        container.serialize_entry("tools", &self.tools)?;
        if let Some(observation) = &self.observation {
            container.serialize_entry("observation", observation)?;
        }
        container.end()
    }
}

/// What a harness asks the session to do next.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionHarnessStep {
    pub action: SessionHarnessStepAction,
    /// `None` keeps the previous state.
    pub state: Option<PluginJSON>,
}

impl SessionHarnessStep {
    pub fn new(action: SessionHarnessStepAction) -> Self {
        Self {
            action,
            state: None,
        }
    }

    pub fn with_state(mut self, state: Option<PluginJSON>) -> Self {
        self.state = state;
        self
    }

    /// The most steps one turn may take.
    pub const MAXIMUM_STEPS: usize = 32;
}

#[derive(Clone, Debug, PartialEq)]
pub enum SessionHarnessStepAction {
    /// Call the model with the session's prompt plus `instructions`;
    /// `message` joins the conversation as a user message first.
    Model {
        instructions: Option<String>,
        message: Option<String>,
    },
    /// Run a tool as the built-in loop would.
    Tool(SessionHarnessTurnCall),
    /// End the turn with a summary. Refused while drafts wait for
    /// `submit_plan`.
    Finish { summary: String },
}

impl<'de> Deserialize<'de> for SessionHarnessStep {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct StepWire {
            step: String,
            instructions: Option<String>,
            message: Option<String>,
            call: Option<SessionHarnessTurnCall>,
            summary: Option<String>,
            state: Option<PluginJSON>,
        }

        let wire = StepWire::deserialize(deserializer)?;
        let action = match wire.step.as_str() {
            "model" => SessionHarnessStepAction::Model {
                instructions: wire.instructions,
                message: wire.message,
            },
            "tool" => SessionHarnessStepAction::Tool(
                wire.call.ok_or_else(|| D::Error::missing_field("call"))?,
            ),
            "finish" => SessionHarnessStepAction::Finish {
                summary: wire
                    .summary
                    .ok_or_else(|| D::Error::missing_field("summary"))?,
            },
            _ => return Err(D::Error::custom("unknown harness step")),
        };
        Ok(Self {
            action,
            state: wire.state,
        })
    }
}

/// The harness of the current conversation and what it carries between steps.
pub(crate) struct SessionHarnessState {
    pub harness: Option<SessionHarness>,
    /// Which harness `state` belongs to.
    pub id: Option<String>,
    pub state: Option<PluginJSON>,
    pub request: SessionHarnessTurnRequest,
    /// Added to the system prompt for the model call a harness asked for.
    pub instructions: Option<String>,
}

impl Default for SessionHarnessState {
    fn default() -> Self {
        Self {
            harness: None,
            id: None,
            state: None,
            request: SessionHarnessTurnRequest::new(String::new(), "en".to_string()),
            instructions: None,
        }
    }
}
