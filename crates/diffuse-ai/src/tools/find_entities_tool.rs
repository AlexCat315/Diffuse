//! Ported from `Engine/Sources/AIRuntime/Tools/FindEntitiesTool.swift`.

use std::collections::BTreeMap;

use diffuse_capability::contracts::exports::JsonSchema;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use serde_json::{Value, json};

const DESCRIPTION: &str = "Search scene entities by name substring, kind, component, or spatial proximity. Returns id, name, kind, components, position, eulerDegrees, scale, worldPosition, parentRef, and all authored property values (light color/range/angles, mesh visibility/material, audio, animation, physics, collider material/layers, script bindings) for each match. Use when you need to find entities that may not be visible in the truncated entity list.";

/// Tool definition for the `find_entities` tool.
/// Lets the AI search by name substring or kind when the scene exceeds the entity prompt limit.
pub enum FindEntitiesTool {}

impl FindEntitiesTool {
    pub const NAME: &'static str = "find_entities";

    /// Anthropic Messages API format.
    pub fn definition() -> Value {
        json!({
            "name": Self::NAME,
            "description": DESCRIPTION,
            "input_schema": Self::schema(),
        })
    }

    /// OpenAI / DeepSeek chat-completions format.
    pub fn open_ai_definition() -> Value {
        json!({
            "type": "function",
            "function": {
                "name": Self::NAME,
                "description": DESCRIPTION,
                "parameters": Self::schema(),
            },
        })
    }

    fn schema() -> Value {
        BuiltInTypedCapabilityCatalog::registry()
            .descriptor("scene.find_entities")
            .map(|descriptor| descriptor.input_schema.canonical_json())
            .unwrap_or_else(|| JsonSchema::object(BTreeMap::new(), Vec::new()).canonical_json())
    }
}
