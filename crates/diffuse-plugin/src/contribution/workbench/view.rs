//! View events, host effects and view results.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Workbench/View.swift`.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::contract::plugin_contract::{PluginInputField, PluginInputType};
use crate::contract::plugin_json::PluginJSON;
use crate::contribution::workbench::command::PluginWorkbenchResultError;
use crate::contribution::workbench::tree::UINode;

/// What the user did in a plugin view, sent back to its entry point.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UIEvent {
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<PluginJSON>,
    /// The new value of the component that raised the event, for fields, toggles
    /// and selects.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<PluginJSON>,
    /// The current value of every field, toggle and select in the view, by
    /// component ID.
    pub values: BTreeMap<String, PluginJSON>,
}

impl UIEvent {
    pub fn new(action: impl Into<String>) -> Self {
        UIEvent {
            action: action.into(),
            arguments: None,
            value: None,
            values: BTreeMap::new(),
        }
    }
}

/// Something the host does for a plugin after a view event or a command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UIEffect {
    Message(String),
    Error(String),
    /// Brings forward one of the package's own panels.
    Panel(String),
    /// Opens a project-relative file in the editor.
    Open(String),
}

impl UIEffect {
    /// `panels` are the package's own panel identifiers.
    pub fn is_valid(&self, panels: &BTreeSet<String>) -> bool {
        match self {
            UIEffect::Message(text) | UIEffect::Error(text) => UINode::is_text(text, false),
            UIEffect::Panel(id) => panels.contains(id),
            UIEffect::Open(path) => {
                !path.is_empty()
                    && path.len() <= 1_024
                    && !path.starts_with('/')
                    && !path.contains('\\')
                    && !path.split('/').any(|part| part == ".." || part.is_empty())
            }
        }
    }
}

impl<'de> Deserialize<'de> for UIEffect {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Coding {
            #[serde(rename = "type")]
            kind: String,
            #[serde(default)]
            text: Option<String>,
            #[serde(default)]
            id: Option<String>,
            #[serde(default)]
            path: Option<String>,
        }
        let coding = Coding::deserialize(deserializer)?;
        let missing =
            |field: &str| serde::de::Error::custom(format!("unknown effect: missing {field}"));
        match coding.kind.as_str() {
            "message" => Ok(UIEffect::Message(
                coding.text.ok_or_else(|| missing("text"))?,
            )),
            "error" => Ok(UIEffect::Error(coding.text.ok_or_else(|| missing("text"))?)),
            "panel" => Ok(UIEffect::Panel(coding.id.ok_or_else(|| missing("id"))?)),
            "open" => Ok(UIEffect::Open(coding.path.ok_or_else(|| missing("path"))?)),
            other => Err(serde::de::Error::custom(format!(
                "unknown effect '{other}'"
            ))),
        }
    }
}

/// What a view entry point returns: the state to hand back next time, the
/// component tree to draw and the effects to carry out.
#[derive(Clone, Debug, PartialEq)]
pub struct PluginViewResult {
    /// `None` keeps the previous state.
    pub state: Option<PluginJSON>,
    pub ui: UINode,
    pub effects: Vec<UIEffect>,
    pub refresh_after_milliseconds: Option<i64>,
}

impl PluginViewResult {
    pub fn new(state: Option<PluginJSON>, ui: UINode, effects: Vec<UIEffect>) -> Self {
        PluginViewResult {
            state,
            ui,
            effects,
            refresh_after_milliseconds: None,
        }
    }

    /// The largest serialized state, so it fits a string input when handed back.
    pub const MAXIMUM_STATE_BYTES: usize = 48 * 1_024;

    /// Reads the JSON object a view entry point returned. `panels` are the
    /// package's own panels.
    pub fn from_json(
        json: &[u8],
        panels: &BTreeSet<String>,
    ) -> Result<Self, PluginWorkbenchResultError> {
        #[derive(Deserialize)]
        struct Coding {
            #[serde(default)]
            state: Option<PluginJSON>,
            ui: UINode,
            #[serde(default)]
            effects: Option<Vec<UIEffect>>,
            #[serde(default, rename = "refreshAfterMilliseconds")]
            refresh_after_milliseconds: Option<i64>,
        }
        if json.len() > 1_024 * 1_024 {
            return Err(PluginWorkbenchResultError::InvalidView);
        }
        let value: serde_json::Value =
            serde_json::from_slice(json).map_err(|_| PluginWorkbenchResultError::InvalidView)?;
        // Swift decoded a keyed container; `not json` and a top-level array both
        // fail there.
        if !value.is_object() {
            return Err(PluginWorkbenchResultError::InvalidView);
        }
        let decoded: Coding =
            serde_json::from_value(value).map_err(|_| PluginWorkbenchResultError::InvalidView)?;
        let effects = decoded.effects.unwrap_or_default();
        let state_size_ok = decoded.state.as_ref().is_none_or(|state| {
            serde_json::to_vec(state)
                .map(|encoded| encoded.len() <= Self::MAXIMUM_STATE_BYTES)
                .unwrap_or(false)
        });
        if !(decoded.ui.is_valid()
            && effects.len() <= 16
            && effects.iter().all(|effect| effect.is_valid(panels))
            && state_size_ok)
        {
            return Err(PluginWorkbenchResultError::InvalidView);
        }
        Ok(PluginViewResult {
            state: decoded.state,
            ui: decoded.ui,
            effects,
            // `min(10_000, max(100, $0))`
            refresh_after_milliseconds: decoded
                .refresh_after_milliseconds
                .map(|value| 10_000.min(100.max(value))),
        })
    }
}

/// `record { view: string, state: string, event: string, context: string }`:
/// the view's ID, the state it last returned, the event as JSON (empty to render
/// only) and what the host knows about where it is shown.
pub fn view_input_type() -> PluginInputType {
    PluginInputType::Record(vec![
        PluginInputField::new("context", PluginInputType::String),
        PluginInputField::new("event", PluginInputType::String),
        PluginInputField::new("state", PluginInputType::String),
        PluginInputField::new("view", PluginInputType::String),
    ])
}
