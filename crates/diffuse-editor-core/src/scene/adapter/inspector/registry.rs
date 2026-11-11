//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Registry.swift`.

use cove_ui_compose::scene_core::{Binding, Color};
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_scene::components::core::registry::ComponentSchema;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::components::inspection::inspection::{
    ComponentColorPresentation, ComponentFieldDescriptor, ComponentFieldKind,
};
use diffuse_scene::entity_id::EntityID;

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldPresentation, EditorInspectorFieldValue,
    EditorInspectorSection, EditorInspectorStringOption,
};

impl EditorSceneAdapter {
    pub(crate) fn registry_inspector_section(
        &self,
        schema: &ComponentSchema,
        entity: EntityID,
    ) -> Option<EditorInspectorSection> {
        let data = self.scene().component_data(&schema.type_id, entity)?;
        let fields: Vec<EditorInspectorField> = schema
            .inspection
            .resolved_fields(&data)
            .into_iter()
            .filter(|field| {
                let Some(visibility) = &field.visibility else {
                    return true;
                };
                let value = data
                    .value_at(&visibility.path)
                    .cloned()
                    .unwrap_or(ComponentValue::Null);
                visibility
                    .values
                    .iter()
                    .any(|candidate| *candidate == value)
            })
            .map(|field| {
                let value = self.registry_field_value(&field, schema, entity);
                EditorInspectorField::with_options(
                    field.id.clone(),
                    localized(&field.label),
                    value,
                    if field.is_advanced {
                        EditorInspectorFieldPresentation::Advanced
                    } else {
                        EditorInspectorFieldPresentation::Standard
                    },
                    false,
                    std::collections::BTreeSet::new(),
                    None,
                    field.group.clone(),
                )
            })
            .collect();
        Some(EditorInspectorSection::new(
            schema
                .inspection
                .section_id
                .clone()
                .unwrap_or_else(|| schema.type_id.clone()),
            localized(&schema.display_name),
            fields,
        ))
    }

    fn registry_field_value(
        &self,
        field: &ComponentFieldDescriptor,
        schema: &ComponentSchema,
        entity: EntityID,
    ) -> EditorInspectorFieldValue {
        if field.is_read_only {
            let value = read_value(self, schema, entity, &field.path);
            return EditorInspectorFieldValue::ReadOnly(match value {
                ComponentValue::Bool(value) => {
                    if value {
                        localized("Yes")
                    } else {
                        localized("No")
                    }
                }
                ComponentValue::String(value) => value,
                other => component_text(&other),
            });
        }
        match field.kind {
            ComponentFieldKind::Boolean => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let get_schema = schema.clone();
                let set_schema = schema.clone();
                let get_path = field.path.clone();
                let set_field = field.clone();
                EditorInspectorFieldValue::Bool(Binding::new(
                    move || {
                        matches!(
                            read_value(&get_adapter, &get_schema, entity, &get_path),
                            ComponentValue::Bool(true)
                        )
                    },
                    move |next: bool| {
                        let path = set_field.path.clone();
                        write_value(
                            &set_adapter,
                            &set_schema,
                            entity,
                            &set_field,
                            &path,
                            ComponentValue::Bool(next),
                        )
                    },
                ))
            }
            ComponentFieldKind::String => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let get_schema = schema.clone();
                let set_schema = schema.clone();
                let get_path = field.path.clone();
                let set_field = field.clone();
                EditorInspectorFieldValue::Text(Binding::new(
                    move || match read_value(&get_adapter, &get_schema, entity, &get_path) {
                        ComponentValue::String(value) => value,
                        _ => String::new(),
                    },
                    move |next: String| {
                        let value = if next.is_empty() && set_field.is_nullable {
                            ComponentValue::Null
                        } else {
                            ComponentValue::String(next)
                        };
                        let path = set_field.path.clone();
                        write_value(&set_adapter, &set_schema, entity, &set_field, &path, value)
                    },
                ))
            }
            ComponentFieldKind::Options => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let get_schema = schema.clone();
                let set_schema = schema.clone();
                let get_path = field.path.clone();
                let set_field = field.clone();
                let read_choices = field.choices.clone();
                let get_choices = read_choices.clone();
                EditorInspectorFieldValue::StringOptions {
                    binding: Binding::new(
                        move || {
                            let current = read_value(&get_adapter, &get_schema, entity, &get_path);
                            get_choices
                                .iter()
                                .find(|choice| choice.value == current)
                                .map(|choice| choice.id.clone())
                                .unwrap_or_default()
                        },
                        move |next: String| {
                            let Some(choice) = set_field
                                .choices
                                .iter()
                                .find(|choice| choice.id == next)
                                .cloned()
                            else {
                                return;
                            };
                            let path = set_field.path.clone();
                            write_value(
                                &set_adapter,
                                &set_schema,
                                entity,
                                &set_field,
                                &path,
                                choice.value,
                            )
                        },
                    ),
                    options: read_choices
                        .iter()
                        .map(|choice| {
                            EditorInspectorStringOption::new(
                                choice.id.clone(),
                                choice.label.clone(),
                            )
                        })
                        .collect(),
                }
            }
            ComponentFieldKind::Number => number_control(self, field, schema, entity),
            ComponentFieldKind::Integer => {
                // Bounded counts fit exactly in Float; seeds and handles retain text editing.
                let numeric = &field.numeric;
                let bounded = match (numeric.minimum, numeric.maximum) {
                    (Some(minimum), Some(maximum)) => {
                        minimum.is_finite()
                            && maximum.is_finite()
                            && minimum.round() == minimum
                            && maximum.round() == maximum
                            && minimum <= maximum
                            && minimum >= -16_777_216.0
                            && maximum <= 16_777_216.0
                            && numeric.scale == 1.0
                    }
                    _ => false,
                };
                if bounded {
                    return number_control(self, field, schema, entity);
                }
                // A Float control cannot represent integer seeds or handles exactly.
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let get_schema = schema.clone();
                let set_schema = schema.clone();
                let get_path = field.path.clone();
                let set_field = field.clone();
                EditorInspectorFieldValue::Text(Binding::new(
                    move || {
                        component_text(&read_value(&get_adapter, &get_schema, entity, &get_path))
                    },
                    move |text: String| {
                        let path = set_field.path.clone();
                        if let Ok(value) = text.parse::<u64>() {
                            write_value(
                                &set_adapter,
                                &set_schema,
                                entity,
                                &set_field,
                                &path,
                                ComponentValue::UnsignedInteger(value),
                            );
                        } else if let Ok(value) = text.parse::<i64>() {
                            write_value(
                                &set_adapter,
                                &set_schema,
                                entity,
                                &set_field,
                                &path,
                                ComponentValue::SignedInteger(value),
                            );
                        }
                    },
                ))
            }
            ComponentFieldKind::Vector3 => EditorInspectorFieldValue::Vector3 {
                x: number_binding(self, field, schema, entity, &path_with(&field.path, "0")),
                y: number_binding(self, field, schema, entity, &path_with(&field.path, "1")),
                z: number_binding(self, field, schema, entity, &path_with(&field.path, "2")),
            },
            ComponentFieldKind::Color => color_field(self, field, schema, entity),
            ComponentFieldKind::Automatic | ComponentFieldKind::Json => {
                let get_adapter = self.clone();
                let set_adapter = self.clone();
                let get_schema = schema.clone();
                let set_schema = schema.clone();
                let get_path = field.path.clone();
                let set_field = field.clone();
                EditorInspectorFieldValue::Json {
                    binding: Binding::new(
                        move || {
                            component_text(&read_value(
                                &get_adapter,
                                &get_schema,
                                entity,
                                &get_path,
                            ))
                        },
                        move |text: String| {
                            let Ok(value) = serde_json::from_str::<ComponentValue>(&text) else {
                                return;
                            };
                            let path = set_field.path.clone();
                            write_value(&set_adapter, &set_schema, entity, &set_field, &path, value)
                        },
                    ),
                    min_height: 100.0,
                }
            }
        }
    }
}

fn path_with(path: &[String], component: &str) -> Vec<String> {
    let mut result = path.to_vec();
    result.push(component.to_string());
    result
}

fn read_value(
    adapter: &EditorSceneAdapter,
    schema: &ComponentSchema,
    entity: EntityID,
    path: &[String],
) -> ComponentValue {
    adapter
        .scene()
        .component_data(&schema.type_id, entity)
        .and_then(|data| data.value_at(path).cloned())
        .unwrap_or(ComponentValue::Null)
}

fn write_value(
    adapter: &EditorSceneAdapter,
    schema: &ComponentSchema,
    entity: EntityID,
    field: &ComponentFieldDescriptor,
    path: &[String],
    value: ComponentValue,
) {
    if field.is_read_only
        || !adapter
            .scene()
            .has_component_by_type_id(&schema.type_id, entity)
        || !value.is_finite_json()
        || read_value(adapter, schema, entity, path) == value
    {
        return;
    }
    let _ = adapter.apply_scene_transaction(
        "scene.set_component_data",
        format!("Update {}", field.label),
        vec![entity.raw_value()],
        vec![SceneMutation::SetComponentData {
            entity_id: entity.raw_value(),
            type_id: schema.type_id.clone(),
            value: ComponentValue::field_patch(value, &field.path),
            mode: ComponentWriteMode::Merge,
        }],
    );
}

fn number_binding(
    adapter: &EditorSceneAdapter,
    field: &ComponentFieldDescriptor,
    schema: &ComponentSchema,
    entity: EntityID,
    path: &[String],
) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    let field = field.clone();
    let get_schema = schema.clone();
    let set_schema = schema.clone();
    let path = path.to_vec();
    let get_path = path.clone();
    Binding::new(
        move || {
            let value = read_value(&get_adapter, &get_schema, entity, &get_path)
                .numeric_value()
                .unwrap_or(0.0);
            (value * field.numeric.scale) as f32
        },
        move |next: f32| {
            if !next.is_finite() || !field.numeric.scale.is_finite() || field.numeric.scale == 0.0 {
                return;
            }
            let mut value = f64::from(next);
            if let Some(minimum) = field.numeric.minimum {
                value = value.max(minimum);
            }
            let resolved_maximum = field
                .numeric
                .maximum_path
                .as_ref()
                .and_then(|maximum_path| {
                    read_value(&set_adapter, &set_schema, entity, maximum_path).numeric_value()
                })
                .map(|maximum| maximum * field.numeric.scale)
                .or(field.numeric.maximum);
            if let Some(maximum) = resolved_maximum {
                value = value.min(maximum);
            }
            if field.kind == ComponentFieldKind::Integer {
                let rounded = value.round();
                if rounded.fract() != 0.0 || rounded < i64::MIN as f64 || rounded > i64::MAX as f64
                {
                    return;
                }
                write_value(
                    &set_adapter,
                    &set_schema,
                    entity,
                    &field,
                    &path,
                    ComponentValue::SignedInteger(rounded as i64),
                );
                return;
            }
            write_value(
                &set_adapter,
                &set_schema,
                entity,
                &field,
                &path,
                ComponentValue::Number(value / field.numeric.scale),
            );
        },
    )
}

fn number_control(
    adapter: &EditorSceneAdapter,
    field: &ComponentFieldDescriptor,
    schema: &ComponentSchema,
    entity: EntityID,
) -> EditorInspectorFieldValue {
    let binding = number_binding(adapter, field, schema, entity, &field.path);
    let numeric = &field.numeric;
    if numeric.minimum.is_some() || numeric.maximum.is_some() || numeric.step.is_some() {
        return EditorInspectorFieldValue::ConstrainedNumber {
            binding,
            min: numeric.minimum.map(|value| value as f32),
            max: numeric.maximum.map(|value| value as f32),
            step: numeric.step.map(|value| value as f32),
            shows_stepper: true,
        };
    }
    EditorInspectorFieldValue::Number(binding)
}

fn color_field(
    adapter: &EditorSceneAdapter,
    field: &ComponentFieldDescriptor,
    schema: &ComponentSchema,
    entity: EntityID,
) -> EditorInspectorFieldValue {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    let get_schema = schema.clone();
    let set_schema = schema.clone();
    let color_field = field.clone();
    let get_path = field.path.clone();
    let set_path = field.path.clone();
    let presentation: ComponentColorPresentation = field.color.clone();
    EditorInspectorFieldValue::Color(Binding::new(
        move || {
            let channels: Vec<Option<f64>> = (0..4)
                .map(|index| {
                    read_value(
                        &get_adapter,
                        &get_schema,
                        entity,
                        &path_with(&get_path, &index.to_string()),
                    )
                    .numeric_value()
                })
                .collect();
            Color {
                r: channels[0].unwrap_or(0.0) as f32,
                g: channels[1].unwrap_or(0.0) as f32,
                b: channels[2].unwrap_or(0.0) as f32,
                a: channels[3].unwrap_or(1.0) as f32,
            }
        },
        move |next: Color| {
            let count = match read_value(&set_adapter, &set_schema, entity, &set_path) {
                ComponentValue::Array(values) => values.len(),
                _ => 4,
            };
            let mut channels = vec![next.r, next.g, next.b, next.a];
            channels.truncate(if count == 3 { 3 } else { 4 });
            if !channels.iter().all(|channel| channel.is_finite()) {
                return;
            }
            let values: Vec<ComponentValue> = channels
                .iter()
                .enumerate()
                .map(|(index, channel)| {
                    let mut value = if index == 3 {
                        0.0_f64.max(f64::from(*channel))
                    } else {
                        presentation.minimum.max(f64::from(*channel))
                    };
                    if let Some(maximum) = if index == 3 {
                        Some(1.0)
                    } else {
                        presentation.maximum
                    } {
                        value = value.min(maximum);
                    }
                    ComponentValue::Number(value)
                })
                .collect();
            write_value(
                &set_adapter,
                &set_schema,
                entity,
                &color_field,
                &set_path,
                ComponentValue::Array(values),
            );
        },
    ))
}

fn component_text(value: &ComponentValue) -> String {
    diffuse_assets::swift_json::to_sorted_pretty(value)
        .map(|text| text.replace("\\/", "/"))
        .unwrap_or_else(|_| "null".to_string())
}
