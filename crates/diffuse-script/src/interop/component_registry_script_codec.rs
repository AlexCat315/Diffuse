//! Registry-local script persistence, preserving handles only for transactions.

use std::collections::BTreeMap;

use diffuse_scene::components::core::registry::{
    ComponentCategory, ComponentEncodePurpose, ComponentRegistry, ComponentSchema,
};
use diffuse_scene::components::core::value::{
    ComponentValue, ManifestComponent, manifest_value_for,
};

use crate::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptAuthoringDefaults {
    pub identifier: String,
}

impl ScriptAuthoringDefaults {
    pub fn new(identifier: impl Into<String>) -> Self {
        Self {
            identifier: identifier.into(),
        }
    }
}

/// Rust extension trait for the SceneRuntime-owned registry type.
pub trait ComponentRegistryScriptCodec {
    fn register_script_codec(&mut self, default_identifier: &str);

    fn register_default_script_codec(&mut self) {
        self.register_script_codec("cove.rotator");
    }
}

impl ComponentRegistryScriptCodec for ComponentRegistry {
    fn register_script_codec(&mut self, default_identifier: &str) {
        if self.get("script").is_some() {
            return;
        }
        let default_identifier = default_identifier.to_string();
        let mut schema = ComponentSchema::for_component::<ScriptComponent>(
            "script",
            "Script",
            ComponentCategory::Scripting,
            |world, entity, context| {
                world.component::<ScriptComponent>(entity).map(|component| {
                    ComponentValue::Object(BTreeMap::from([(
                        "bindings".to_string(),
                        ComponentValue::Array(
                            component
                                .bindings
                                .iter()
                                .map(|binding| {
                                    ComponentValue::Object(
                                        if context.purpose == ComponentEncodePurpose::Transaction {
                                            encode_script_binding_for_editing(binding)
                                        } else {
                                            encode_script_binding(binding)
                                        },
                                    )
                                })
                                .collect(),
                        ),
                    )]))
                })
            },
            |value, entity, _context, world| {
                let Some(dictionary) = value.object_value() else {
                    return;
                };
                let raw = binding_documents(dictionary.get("bindings")).unwrap_or_default();
                let _ = world.set_component(
                    ScriptComponent::new(raw.into_iter().map(decode_script_binding).collect()),
                    entity,
                );
            },
            move |entity, world| {
                let identifier = world
                    .resource::<ScriptAuthoringDefaults>()
                    .map(|v| v.identifier)
                    .unwrap_or_else(|| default_identifier.clone());
                let _ = world.set_component(
                    ScriptComponent::new(vec![ScriptBinding::with_identifier(identifier)]),
                    entity,
                );
            },
        );
        schema.apply_edit = |value, entity, _context, world| {
            let Some(raw) = value
                .object_value()
                .and_then(|v| binding_documents(v.get("bindings")))
            else {
                return;
            };
            let previous = world
                .component::<ScriptComponent>(entity)
                .map(|v| v.bindings)
                .unwrap_or_default();
            let bindings =
                raw.into_iter()
                    .map(|encoded| {
                        let mut binding = decode_script_binding(encoded);
                        if let Some(old) = previous.iter().find(|old| {
                            old.id == binding.id && old.identifier == binding.identifier
                        }) {
                            binding.script = old.script;
                        } else if let Some(handle) =
                            encoded.get("scriptHandle").and_then(number_uint64_value)
                        {
                            binding.script = ScriptHandle::new(handle);
                        }
                        binding
                    })
                    .collect();
            let _ = world.set_component(ScriptComponent::new(bindings), entity);
        };
        self.register(schema);
    }
}

fn binding_documents(
    value: Option<&ComponentValue>,
) -> Option<Vec<&BTreeMap<String, ComponentValue>>> {
    value?
        .as_array()?
        .iter()
        .map(ComponentValue::object_value)
        .collect()
}

pub fn scene_document_scripts(components: &[ManifestComponent]) -> Option<Vec<ScriptBinding>> {
    let document = manifest_value_for(components, "script")?.object_value()?;
    Some(
        binding_documents(document.get("bindings"))?
            .into_iter()
            .map(decode_script_binding)
            .collect(),
    )
}

pub fn encode_script_binding(binding: &ScriptBinding) -> BTreeMap<String, ComponentValue> {
    let mut value = BTreeMap::from([
        (
            "bindingID".to_string(),
            ComponentValue::String(binding.id.uuid_string()),
        ),
        (
            "parametersJSON".to_string(),
            ComponentValue::String(binding.parameters_json.clone()),
        ),
        (
            "isEnabled".to_string(),
            ComponentValue::Bool(binding.is_enabled),
        ),
    ]);
    if let Some(identifier) = &binding.identifier {
        value.insert(
            "identifier".to_string(),
            ComponentValue::String(identifier.clone()),
        );
    }
    value
}

pub fn decode_script_binding(value: &BTreeMap<String, ComponentValue>) -> ScriptBinding {
    ScriptBinding::new(
        ScriptHandle::new(0),
        value
            .get("bindingID")
            .and_then(ComponentValue::as_str)
            .and_then(ScriptBindingID::from_uuid_string)
            .unwrap_or_default(),
        value
            .get("identifier")
            .and_then(ComponentValue::as_str)
            .map(str::to_string),
        value
            .get("isEnabled")
            .and_then(ComponentValue::as_bool)
            .unwrap_or(true),
        value
            .get("parametersJSON")
            .and_then(ComponentValue::as_str)
            .unwrap_or("{}"),
    )
}

pub fn encode_script_binding_for_editing(
    binding: &ScriptBinding,
) -> BTreeMap<String, ComponentValue> {
    let mut value = encode_script_binding(binding);
    value.insert(
        "scriptHandle".to_string(),
        ComponentValue::from_json_value(&serde_json::Value::from(binding.script.raw_value)),
    );
    value
}

fn number_uint64_value(value: &ComponentValue) -> Option<u64> {
    match value {
        ComponentValue::UnsignedInteger(v) => Some(*v),
        ComponentValue::SignedInteger(v) => Some(*v as u64),
        ComponentValue::Number(v) => Some(if v.is_finite() {
            if *v < 0.0 && *v >= i64::MIN as f64 {
                (*v as i64) as u64
            } else {
                v.trunc().rem_euclid(18_446_744_073_709_551_616.0) as u64
            }
        } else {
            0
        }),
        ComponentValue::Bool(v) => Some(u64::from(*v)),
        _ => None,
    }
}
