//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/ScriptBindings.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::scene_bootstrap::SceneNameComponent;
use diffuse_script::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptDefinition, ScriptParameterIssue,
    ScriptProperty, ScriptPropertyValue,
};

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::adapter::scripts::bindings_component_value;
use crate::scene::adapter::support::editor_scene_json::normalized_json_commit_text;
use crate::scene::editor_inspector_schema::{
    EditorInspectorEntityOption, EditorInspectorField, EditorInspectorFieldGroup,
    EditorInspectorFieldPresentation, EditorInspectorFieldValue, EditorInspectorSection,
    EditorInspectorStringOption,
};

impl EditorSceneAdapter {
    pub(crate) fn script_section(&self, entity: EntityID) -> Option<EditorInspectorSection> {
        let component = self.scene().component::<ScriptComponent>(entity)?;
        let mut fields: Vec<EditorInspectorField> = Vec::new();
        let mut groups: Vec<EditorInspectorFieldGroup> = Vec::new();
        let options = self.available_script_options();
        for (index, binding) in component.bindings.iter().enumerate() {
            let prefix = format!("script-{index}");
            let identifier = binding
                .identifier
                .clone()
                .or_else(|| self.script_runtime.identifier(binding.script))
                .unwrap_or_default();
            let source_identifier = self.dynamic_script_source_identifier(&identifier);
            let lookup_identifier = source_identifier
                .clone()
                .unwrap_or_else(|| identifier.clone());
            let title = options
                .iter()
                .find(|option| option.value == lookup_identifier)
                .map(|option| option.label.clone())
                .unwrap_or(identifier.clone());
            let definition = self.script_runtime.definition(binding);
            let mut property_ids: Vec<String> = Vec::new();
            fields.push(EditorInspectorField::new(
                format!("{prefix}-identifier"),
                localized("Script"),
                EditorInspectorFieldValue::StringOptions {
                    binding: self.script_identifier_binding(entity, binding.id.clone()),
                    options: options.clone(),
                },
            ));
            fields.push(EditorInspectorField::new(
                format!("{prefix}-enabled"),
                localized("Enabled"),
                EditorInspectorFieldValue::Bool(
                    self.script_enabled_binding(entity, binding.id.clone()),
                ),
            ));
            fields.push(EditorInspectorField::new(
                format!("{prefix}-status"),
                localized("Status"),
                EditorInspectorFieldValue::ReadOnly(self.script_status(
                    binding,
                    entity,
                    &source_identifier,
                )),
            ));
            for property in definition
                .as_ref()
                .map(|definition| definition.properties.clone())
                .unwrap_or_default()
            {
                let field_id = format!("{prefix}-property-{}", property.key);
                property_ids.push(field_id.clone());
                fields.push(EditorInspectorField::with_options(
                    field_id,
                    localized(&property.label),
                    self.script_property_field(&property, entity, binding.id.clone()),
                    EditorInspectorFieldPresentation::Standard,
                    false,
                    std::collections::BTreeSet::new(),
                    None,
                    property.group.as_ref().map(|group| localized(group)),
                ));
            }
            if let Some(definition) = &definition {
                let issues = definition.parameter_issues(&binding.parameters_json);
                if !issues.is_empty() {
                    let field_id = format!("{prefix}-issues");
                    property_ids.push(field_id.clone());
                    let text = issues
                        .iter()
                        .map(|issue| match issue {
                            ScriptParameterIssue::InvalidDocument => {
                                localized("Parameters must be a JSON object")
                            }
                            ScriptParameterIssue::Unknown(key) => {
                                format!("{}: {key}", localized("Unknown parameter"))
                            }
                            ScriptParameterIssue::Invalid(key) => {
                                format!("{}: {key}", localized("Invalid parameter"))
                            }
                        })
                        .collect::<Vec<_>>()
                        .join("; ");
                    fields.push(EditorInspectorField::new(
                        field_id,
                        localized("Parameter Issues"),
                        EditorInspectorFieldValue::ReadOnly(text),
                    ));
                }
            }
            if definition
                .as_ref()
                .map(|definition| definition.properties.is_empty())
                .unwrap_or(true)
            {
                let field_id = format!("{prefix}-interface");
                property_ids.push(field_id.clone());
                fields.push(EditorInspectorField::new(
                    field_id,
                    localized("Properties"),
                    EditorInspectorFieldValue::ReadOnly(
                        if definition.is_none() && source_identifier.is_some() {
                            localized("Build script to load properties")
                        } else {
                            localized("No exposed properties")
                        },
                    ),
                ));
            }
            property_ids.push(format!("{prefix}-parameters"));
            fields.push(EditorInspectorField::with_options(
                format!("{prefix}-parameters"),
                localized("Advanced Parameters (JSON)"),
                EditorInspectorFieldValue::Json {
                    binding: self.script_parameters_binding(entity, binding.id.clone()),
                    min_height: 96.0,
                },
                EditorInspectorFieldPresentation::Advanced,
                false,
                std::collections::BTreeSet::new(),
                None,
                None,
            ));
            {
                let action_adapter = self.clone();
                let binding_id = binding.id.clone();
                fields.push(EditorInspectorField::new(
                    format!("{prefix}-reset"),
                    localized("Reset Properties"),
                    EditorInspectorFieldValue::Action {
                        title: localized("Reset Properties"),
                        is_destructive: false,
                        action: std::rc::Rc::new(move || {
                            action_adapter.update_script_binding(
                                entity,
                                binding_id.clone(),
                                "scene.reset_script_parameters",
                                "Reset script property overrides",
                                |binding| binding.parameters_json = "{}".to_string(),
                            );
                        }),
                    },
                ));
            }
            {
                let action_adapter = self.clone();
                let binding_id = binding.id.clone();
                fields.push(EditorInspectorField::new(
                    format!("{prefix}-remove"),
                    localized("Remove Script"),
                    EditorInspectorFieldValue::Action {
                        title: localized("Remove Script"),
                        is_destructive: true,
                        action: std::rc::Rc::new(move || {
                            let Some(bindings) = action_adapter
                                .scene()
                                .component::<ScriptComponent>(entity)
                                .map(|component| component.bindings)
                            else {
                                return;
                            };
                            let Some(current_index) =
                                bindings.iter().position(|binding| binding.id == binding_id)
                            else {
                                return;
                            };
                            let _ = action_adapter
                                .remove_script_binding(entity.raw_value(), current_index);
                        }),
                    },
                ));
            }
            groups.push(EditorInspectorFieldGroup::with_source_identifier(
                format!("scripts/{}", binding.id.uuid_string()),
                if title.is_empty() {
                    localized("Missing script")
                } else {
                    title
                },
                property_ids,
                format!("{prefix}-enabled"),
                format!("{prefix}-status"),
                format!("{prefix}-identifier"),
                vec![format!("{prefix}-reset"), format!("{prefix}-remove")],
                source_identifier,
            ));
        }
        if fields.is_empty() {
            fields.push(EditorInspectorField::new(
                "script-empty",
                localized("Scripts"),
                EditorInspectorFieldValue::ReadOnly(localized("No scripts")),
            ));
        }
        {
            let action_adapter = self.clone();
            fields.push(EditorInspectorField::new(
                "script-add",
                "",
                EditorInspectorFieldValue::Action {
                    title: localized("Add Script"),
                    is_destructive: false,
                    action: std::rc::Rc::new(move || {
                        let _ = action_adapter.add_script_binding(entity.raw_value());
                    }),
                },
            ));
        }
        Some(EditorInspectorSection::with_groups(
            "scripts",
            localized("Scripts"),
            fields,
            groups,
            None,
            true,
        ))
    }

    fn script_status(
        &self,
        binding: &ScriptBinding,
        entity: EntityID,
        source_identifier: &Option<String>,
    ) -> String {
        if !self.script_runtime.can_resolve(binding) {
            return if source_identifier.is_none() {
                localized("Missing script")
            } else {
                localized("Not Built")
            };
        }
        if !binding.is_enabled {
            return localized("Disabled");
        }
        if self.script_runtime.needs_reload(binding, entity) {
            return localized("Reload Pending");
        }
        if self.script_runtime.is_active(binding, entity) {
            return localized("Running");
        }
        localized("Loaded")
    }

    fn script_binding_for(&self, entity: EntityID, id: ScriptBindingID) -> Option<ScriptBinding> {
        self.scene()
            .component::<ScriptComponent>(entity)
            .and_then(|component| {
                component
                    .bindings
                    .into_iter()
                    .find(|binding| binding.id == id)
            })
    }

    fn update_script_binding(
        &self,
        entity: EntityID,
        id: ScriptBindingID,
        verb: &str,
        summary: &str,
        update: impl FnOnce(&mut ScriptBinding),
    ) {
        let Some(mut bindings) = self
            .scene()
            .component::<ScriptComponent>(entity)
            .map(|component| component.bindings)
        else {
            return;
        };
        let Some(index) = bindings.iter().position(|binding| binding.id == id) else {
            return;
        };
        let previous = bindings[index].clone();
        update(&mut bindings[index]);
        if previous == bindings[index] {
            return;
        }
        let _ = self.apply_scene_transaction(
            verb,
            summary,
            vec![entity.raw_value()],
            vec![SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "script".to_string(),
                value: bindings_component_value(&bindings),
                mode: ComponentWriteMode::Replace,
            }],
        );
    }

    fn script_enabled_binding(&self, entity: EntityID, id: ScriptBindingID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        let get_id = id.clone();
        Binding::new(
            move || {
                get_adapter
                    .script_binding_for(entity, get_id.clone())
                    .map(|binding| binding.is_enabled)
                    .unwrap_or(false)
            },
            move |next: bool| {
                set_adapter.update_script_binding(
                    entity,
                    id.clone(),
                    "scene.set_script_enabled",
                    "Update script enabled flag",
                    |binding| binding.is_enabled = next,
                );
            },
        )
    }

    fn script_identifier_binding(&self, entity: EntityID, id: ScriptBindingID) -> Binding<String> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        let get_id = id.clone();
        Binding::new(
            move || {
                let Some(binding) = get_adapter.script_binding_for(entity, get_id.clone()) else {
                    return String::new();
                };
                binding.identifier.clone().unwrap_or_else(|| {
                    get_adapter
                        .script_runtime
                        .identifier(binding.script)
                        .unwrap_or_else(|| format!("handle:#{}", binding.script.raw_value))
                })
            },
            move |next: String| {
                let normalized = next.trim();
                if normalized.is_empty() {
                    return;
                }
                let current = set_adapter
                    .script_binding_for(entity, id.clone())
                    .and_then(|binding| binding.identifier);
                if current.as_deref() == Some(normalized) {
                    return;
                }
                let handle = set_adapter
                    .script_runtime
                    .handle(normalized)
                    .unwrap_or_else(|| diffuse_script::ScriptHandle::new(0));
                let identifier = normalized.to_string();
                set_adapter.update_script_binding(
                    entity,
                    id.clone(),
                    "scene.set_script_identifier",
                    "Change script binding",
                    |binding| {
                        binding.identifier = Some(identifier.clone());
                        binding.script = handle;
                        binding.parameters_json = "{}".to_string();
                    },
                );
            },
        )
    }

    fn script_parameters_binding(&self, entity: EntityID, id: ScriptBindingID) -> Binding<String> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        let get_id = id.clone();
        Binding::new(
            move || {
                let parameters = get_adapter
                    .script_binding_for(entity, get_id.clone())
                    .map(|binding| binding.parameters_json)
                    .unwrap_or_else(|| "{}".to_string());
                normalized_json_commit_text(&parameters)
            },
            move |next: String| {
                let normalized = normalized_json_commit_text(&next);
                let is_object =
                    serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&normalized)
                        .is_ok();
                if !is_object {
                    return;
                }
                set_adapter.update_script_binding(
                    entity,
                    id.clone(),
                    "scene.set_script_parameters",
                    "Update script parameters",
                    |binding| binding.parameters_json = normalized.clone(),
                );
            },
        )
    }

    fn script_property_value(
        &self,
        property: &ScriptProperty,
        entity: EntityID,
        id: ScriptBindingID,
    ) -> ScriptPropertyValue {
        let Some(binding) = self.script_binding_for(entity, id) else {
            return property.default_value.clone();
        };
        let overrides = ScriptDefinition::decode_parameters(&binding.parameters_json);
        let defaults = self.script_runtime.default_parameters(&binding);
        if let Some(value) = overrides.get(&property.key)
            && property.accepts(value)
            && let Some(decoded) = property.default_value.decoding(value)
        {
            return decoded;
        }
        if let Some(value) = defaults.get(&property.key)
            && property.accepts(value)
            && let Some(decoded) = property.default_value.decoding(value)
        {
            return decoded;
        }
        property.default_value.clone()
    }

    fn set_script_property(
        &self,
        property: &ScriptProperty,
        value: ScriptPropertyValue,
        entity: EntityID,
        id: ScriptBindingID,
    ) {
        let Some(binding) = self.script_binding_for(entity, id.clone()) else {
            return;
        };
        if !property.accepts(&value.json_value()) {
            return;
        }
        let matches_definition = self
            .script_runtime
            .definition(&binding)
            .is_some_and(|definition| definition.properties.contains(property));
        if !matches_definition {
            return;
        }
        let mut overrides = ScriptDefinition::decode_parameters(&binding.parameters_json);
        let defaults = self.script_runtime.default_parameters(&binding);
        let default_value = defaults
            .get(&property.key)
            .and_then(|value| property.default_value.decoding(value))
            .unwrap_or_else(|| property.default_value.clone());
        if value == default_value {
            overrides.remove(&property.key);
        } else {
            overrides.insert(property.key.clone(), value.json_value());
        }
        let Some(json) = ScriptDefinition::encode_parameters(overrides) else {
            return;
        };
        let summary = format!("Update script property {}", property.key);
        self.update_script_binding(
            entity,
            id,
            "scene.set_script_parameters",
            &summary,
            |binding| binding.parameters_json = json.clone(),
        );
    }

    fn script_property_field(
        &self,
        property: &ScriptProperty,
        entity: EntityID,
        id: ScriptBindingID,
    ) -> EditorInspectorFieldValue {
        match property.default_value {
            ScriptPropertyValue::String(_) => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let property_get = property.clone();
                let property_set = property.clone();
                let id_get = id.clone();
                let id_set = id.clone();
                let value = Binding::new(
                    move || match get_adapter.script_property_value(
                        &property_get,
                        entity,
                        id_get.clone(),
                    ) {
                        ScriptPropertyValue::String(value) => value,
                        _ => String::new(),
                    },
                    move |next: String| {
                        set_adapter.set_script_property(
                            &property_set,
                            ScriptPropertyValue::String(next),
                            entity,
                            id_set.clone(),
                        );
                    },
                );
                if property.options.is_empty() {
                    EditorInspectorFieldValue::Text(value)
                } else {
                    EditorInspectorFieldValue::StringOptions {
                        binding: value,
                        options: property
                            .options
                            .iter()
                            .map(|option| {
                                EditorInspectorStringOption::new(
                                    option.value.clone(),
                                    localized(&option.label),
                                )
                            })
                            .collect(),
                    }
                }
            }
            ScriptPropertyValue::Boolean(_) => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let property_get = property.clone();
                let property_set = property.clone();
                let id_get = id.clone();
                let id_set = id.clone();
                EditorInspectorFieldValue::Bool(Binding::new(
                    move || {
                        matches!(
                            get_adapter.script_property_value(
                                &property_get,
                                entity,
                                id_get.clone()
                            ),
                            ScriptPropertyValue::Boolean(true)
                        )
                    },
                    move |next: bool| {
                        set_adapter.set_script_property(
                            &property_set,
                            ScriptPropertyValue::Boolean(next),
                            entity,
                            id_set.clone(),
                        );
                    },
                ))
            }
            ScriptPropertyValue::Number(_) | ScriptPropertyValue::Integer(_) => {
                let is_integer = matches!(property.default_value, ScriptPropertyValue::Integer(_));
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let property_get = property.clone();
                let property_set = property.clone();
                let id_get = id.clone();
                let id_set = id.clone();
                let value = Binding::new(
                    move || match get_adapter.script_property_value(
                        &property_get,
                        entity,
                        id_get.clone(),
                    ) {
                        ScriptPropertyValue::Number(number) => number as f32,
                        ScriptPropertyValue::Integer(integer) => integer as f32,
                        _ => 0.0,
                    },
                    move |next: f32| {
                        let value = if is_integer {
                            let rounded = f64::from(next).round();
                            ScriptPropertyValue::Integer(
                                (rounded >= i64::MIN as f64 && rounded <= i64::MAX as f64)
                                    .then_some(rounded as i64)
                                    .unwrap_or(0),
                            )
                        } else {
                            ScriptPropertyValue::Number(f64::from(next))
                        };
                        set_adapter.set_script_property(
                            &property_set,
                            value,
                            entity,
                            id_set.clone(),
                        );
                    },
                );
                EditorInspectorFieldValue::ConstrainedNumber {
                    binding: value,
                    min: property.minimum.map(|value| value as f32),
                    max: property.maximum.map(|value| value as f32),
                    step: property.step.map(|value| value as f32).or(if is_integer {
                        Some(1.0)
                    } else {
                        None
                    }),
                    shows_stepper: false,
                }
            }
            ScriptPropertyValue::Entity(_) => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let property_get = property.clone();
                let property_set = property.clone();
                let id_get = id.clone();
                let id_set = id.clone();
                let scene = self.scene();
                let mut options = vec![EditorInspectorEntityOption::new(0, localized("None"))];
                options.extend(scene.entities().into_iter().map(|entity| {
                    let name = scene
                        .component::<SceneNameComponent>(entity)
                        .map(|component| component.value)
                        .unwrap_or_else(|| format!("Entity {}", entity.raw_value()));
                    EditorInspectorEntityOption::new(entity.raw_value(), name)
                }));
                EditorInspectorFieldValue::EntityReference {
                    binding: Binding::new(
                        move || match get_adapter.script_property_value(
                            &property_get,
                            entity,
                            id_get.clone(),
                        ) {
                            ScriptPropertyValue::Entity(value) => value,
                            _ => 0,
                        },
                        move |next: u64| {
                            set_adapter.set_script_property(
                                &property_set,
                                ScriptPropertyValue::Entity(next),
                                entity,
                                id_set.clone(),
                            );
                        },
                    ),
                    options,
                }
            }
            ScriptPropertyValue::Vector3(_) => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let property_get = property.clone();
                let property_set = property.clone();
                let id_get = id.clone();
                let id_set = id.clone();
                let axis = |axis: TransformAxis| {
                    let get_adapter = get_adapter.clone();
                    let set_adapter = set_adapter.clone();
                    let property_get = property_get.clone();
                    let property_set = property_set.clone();
                    let id_get = id_get.clone();
                    let id_set = id_set.clone();
                    Binding::new(
                        move || match get_adapter.script_property_value(
                            &property_get,
                            entity,
                            id_get.clone(),
                        ) {
                            ScriptPropertyValue::Vector3(value) => axis_value(value, axis),
                            _ => 0.0,
                        },
                        move |next: f32| {
                            let current = set_adapter.script_property_value(
                                &property_set,
                                entity,
                                id_set.clone(),
                            );
                            let ScriptPropertyValue::Vector3(mut value) = current else {
                                return;
                            };
                            value = set_axis_value(value, axis, next);
                            set_adapter.set_script_property(
                                &property_set,
                                ScriptPropertyValue::Vector3(value),
                                entity,
                                id_set.clone(),
                            );
                        },
                    )
                };
                EditorInspectorFieldValue::Vector3 {
                    x: axis(TransformAxis::X),
                    y: axis(TransformAxis::Y),
                    z: axis(TransformAxis::Z),
                }
            }
        }
    }
}

#[derive(Clone, Copy)]
enum TransformAxis {
    X,
    Y,
    Z,
}

fn axis_value(value: diffuse_math::simd::simd_compat::Float3, axis: TransformAxis) -> f32 {
    match axis {
        TransformAxis::X => value.x,
        TransformAxis::Y => value.y,
        TransformAxis::Z => value.z,
    }
}

fn set_axis_value(
    value: diffuse_math::simd::simd_compat::Float3,
    axis: TransformAxis,
    component: f32,
) -> diffuse_math::simd::simd_compat::Float3 {
    match axis {
        TransformAxis::X => {
            diffuse_math::simd::simd_compat::Float3::new(component, value.y, value.z)
        }
        TransformAxis::Y => {
            diffuse_math::simd::simd_compat::Float3::new(value.x, component, value.z)
        }
        TransformAxis::Z => {
            diffuse_math::simd::simd_compat::Float3::new(value.x, value.y, component)
        }
    }
}
