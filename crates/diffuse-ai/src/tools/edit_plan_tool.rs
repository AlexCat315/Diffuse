//! Ported from `Engine/Sources/AIRuntime/Tools/EditPlanTool.swift`.

use std::collections::BTreeMap;

use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::contracts::exports::{JsonSchema, JsonSchemaScalar};
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use serde_json::{Value, json};

use crate::planning::scene_edit_plan::SceneEditOp;

const DESCRIPTION: &str = "Propose an ordered scene edit plan. This call never bypasses capability validation or confirmation.";

/// Compatibility multi-step tool. Its schema is assembled exclusively from the
/// same capability contracts used by validation, MCP, and permission planning.
pub enum EditPlanTool {}

impl EditPlanTool {
    pub const NAME: &'static str = "execute_edit_plan";

    /// Swift default: `CapabilityRegistry.aiDefault`.
    pub fn definition_with_defaults() -> Value {
        Self::definition(&BuiltInTypedCapabilityCatalog::registry())
    }

    pub fn definition(registry: &CapabilityRegistry) -> Value {
        json!({
            "name": Self::NAME,
            "description": DESCRIPTION,
            "input_schema": Self::schema(registry),
        })
    }

    pub fn open_ai_definition_with_defaults() -> Value {
        Self::open_ai_definition(&BuiltInTypedCapabilityCatalog::registry())
    }

    pub fn open_ai_definition(registry: &CapabilityRegistry) -> Value {
        json!({
            "type": "function",
            "function": {
                "name": Self::NAME,
                "description": DESCRIPTION,
                "parameters": Self::schema(registry),
            },
        })
    }

    pub fn schema_with_defaults() -> Value {
        Self::schema(&BuiltInTypedCapabilityCatalog::registry())
    }

    pub fn schema(registry: &CapabilityRegistry) -> Value {
        Self::json_schema(registry).canonical_json()
    }

    /// The typed form is used by registries and transports that need to retain
    /// the contract metadata instead of immediately serializing it.
    pub fn json_schema_with_defaults() -> JsonSchema {
        Self::json_schema(&BuiltInTypedCapabilityCatalog::registry())
    }

    pub fn json_schema(registry: &CapabilityRegistry) -> JsonSchema {
        let step_schemas: Vec<JsonSchema> = if registry.integrity_errors.is_empty() {
            SceneEditOp::ALL
                .iter()
                .filter_map(|operation| {
                    let descriptor = registry.descriptor(operation.capability_id())?;
                    if !(descriptor.is_ai_exposed
                        && (!descriptor.access.is_write()
                            || descriptor.input_schema.is_strict_capability_input()))
                    {
                        return None;
                    }
                    let mut properties = descriptor.input_schema.properties.clone();
                    properties.insert(
                        "op".to_string(),
                        JsonSchema {
                            r#type: Some(
                                diffuse_capability::contracts::exports::JsonSchemaType::String,
                            ),
                            description: Some("Compatibility operation name.".to_string()),
                            allowed_values: vec![JsonSchemaScalar::String(
                                operation.raw_value().to_string(),
                            )],
                            ..JsonSchema::default()
                        },
                    );
                    let mut required = descriptor.input_schema.required.clone();
                    required.push("op".to_string());
                    Some(JsonSchema::object(properties, required))
                })
                .collect()
        } else {
            Vec::new()
        };
        // An invalid/empty registry must not degrade to an untyped `items: {}`
        // schema. `maxItems: 0` preserves read-only/no-op plans and rejects all
        // mutation steps until registry integrity is restored.
        let empty = step_schemas.is_empty();
        let step_item_schema = if empty {
            JsonSchema::null()
        } else {
            JsonSchema::choice(step_schemas)
        };
        let maximum_steps = if empty { 0 } else { 100 };

        let mut properties: BTreeMap<String, JsonSchema> = BTreeMap::new();
        properties.insert(
            "summary".to_string(),
            JsonSchema {
                description: Some("One-line description of the complete plan.".to_string()),
                ..JsonSchema::string(None, None)
            },
        );
        properties.insert(
            "reasoning".to_string(),
            JsonSchema {
                description: Some("Brief explanation for diagnostics.".to_string()),
                ..JsonSchema::string(None, None)
            },
        );
        properties.insert(
            "scene_revision".to_string(),
            JsonSchema {
                description: Some(
                    "Scene revision returned by get_scene_entities; stale plans are rejected."
                        .to_string(),
                ),
                ..JsonSchema::integer(Some(0.0), None)
            },
        );
        properties.insert(
            "steps".to_string(),
            JsonSchema {
                description: Some("Ordered capability invocations.".to_string()),
                ..JsonSchema::array_of(step_item_schema, Some(maximum_steps))
            },
        );
        JsonSchema::object(
            properties,
            vec![
                "summary".to_string(),
                "scene_revision".to_string(),
                "steps".to_string(),
            ],
        )
    }
}
