//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/MultiSelection.swift`.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

use cove_ui_compose::scene_core::{Binding, Color};
use diffuse_scene::particles::particle_curve::ParticleCurve;
use diffuse_scene::particles::particle_events::ParticleSubEmitter;
use diffuse_scene::particles::particle_modules::ParticleModuleStack;
use diffuse_scene::physics::collider::ColliderShapeInstance;

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorAssetRef, EditorInspectorEntityOption, EditorInspectorField,
    EditorInspectorFieldGroup, EditorInspectorFieldValue, EditorInspectorSection,
    EditorInspectorSectionLayout, EditorInspectorStringOption,
};

impl EditorSceneAdapter {
    /// Intersects the schema by section, field and value type. Bindings retain
    /// each entity's own values, so editing one vector axis preserves the others.
    pub fn inspector_sections_for_selection(
        &self,
        raw_ids: &BTreeSet<u64>,
        primary_id: Option<u64>,
    ) -> Vec<EditorInspectorSection> {
        let mut ids: Vec<u64> = raw_ids.iter().copied().collect();
        if let Some(primary_id) = primary_id
            && let Some(index) = ids.iter().position(|id| *id == primary_id)
        {
            let primary = ids.remove(index);
            ids.insert(0, primary);
        }
        if ids.is_empty()
            || !ids
                .iter()
                .all(|id| self.entity_summary(Some(*id)).is_some())
        {
            return Vec::new();
        }
        if ids.len() == 1 {
            return self.inspector_sections(Some(ids[0]));
        }
        let schemas: Vec<Vec<EditorInspectorSection>> = ids
            .iter()
            .map(|id| self.inspector_sections(Some(*id)))
            .collect();
        let mut result: Vec<EditorInspectorSection> = Vec::new();
        for section in &schemas[0] {
            if !section.supports_multi_selection
                || ["physics-settings", "particle-scalability"].contains(&section.id.as_str())
            {
                continue;
            }
            let matches: Vec<&EditorInspectorSection> = schemas
                .iter()
                .filter_map(|sections| sections.iter().find(|candidate| candidate.id == section.id))
                .collect();
            if matches.len() != ids.len() {
                continue;
            }
            let mut fields: Vec<EditorInspectorField> = Vec::new();
            for field in &section.fields {
                let values: Vec<EditorInspectorFieldValue> = matches
                    .iter()
                    .filter_map(|section| {
                        section
                            .fields
                            .iter()
                            .find(|candidate| candidate.id == field.id)
                            .map(|candidate| candidate.value.clone())
                    })
                    .collect();
                if values.len() != ids.len() {
                    continue;
                }
                let batch = Rc::new(RefCell::new(InspectorFieldBatch {
                    scene: self.clone(),
                    ids: raw_ids.clone(),
                    values,
                    section_id: section.id.clone(),
                    field_id: field.id.clone(),
                    is_mixed: false,
                    mixed_axes: BTreeSet::new(),
                    primary_value_setters: Vec::new(),
                }));
                let Some(value) = batch.borrow_mut().value() else {
                    continue;
                };
                let is_mixed = batch.borrow().is_mixed;
                let mixed_axes = batch.borrow().mixed_axes.clone();
                let apply_primary = if batch.borrow().can_apply_primary(&value) {
                    let batch = batch.clone();
                    Some(Rc::new(move || {
                        batch.borrow().apply_primary_value();
                    }) as Rc<dyn Fn()>)
                } else {
                    None
                };
                fields.push(EditorInspectorField::with_options(
                    field.id.clone(),
                    field.label.clone(),
                    value,
                    field.presentation,
                    is_mixed,
                    mixed_axes,
                    apply_primary,
                    field.group.clone(),
                ));
            }
            if fields.is_empty() {
                continue;
            }
            let groups: Vec<EditorInspectorFieldGroup> = section
                .groups
                .iter()
                .filter(|group| {
                    let identifiers: Vec<String> = matches
                        .iter()
                        .filter_map(|section| {
                            let value = section
                                .fields
                                .iter()
                                .find(|field| field.id == group.selector_field_id)
                                .map(|field| &field.value)?;
                            match value {
                                EditorInspectorFieldValue::StringOptions { binding, .. } => {
                                    Some(binding.get())
                                }
                                _ => None,
                            }
                        })
                        .collect();
                    identifiers.len() == ids.len()
                        && identifiers.iter().collect::<BTreeSet<_>>().len() == 1
                })
                .cloned()
                .collect();
            let script_layout = section.component_type_id.as_ref().map(|component_type_id| {
                self.inspector_renderers
                    .borrow()
                    .layout_for(component_type_id)
            });
            if script_layout == Some(EditorInspectorSectionLayout::ScriptBindings)
                && !section.groups.is_empty()
                && groups.is_empty()
            {
                let mut mixed = section.clone();
                mixed.fields = vec![EditorInspectorField::new(
                    "script-mixed",
                    localized("Scripts"),
                    EditorInspectorFieldValue::ReadOnly(localized("Different script behaviors")),
                )];
                mixed.groups = Vec::new();
                result.push(mixed);
                continue;
            }
            let mut merged = section.clone();
            merged.fields = fields;
            merged.groups = groups;
            result.push(merged);
        }
        result
    }
}

struct InspectorFieldBatch {
    scene: EditorSceneAdapter,
    ids: BTreeSet<u64>,
    values: Vec<EditorInspectorFieldValue>,
    section_id: String,
    field_id: String,
    is_mixed: bool,
    mixed_axes: BTreeSet<String>,
    primary_value_setters: Vec<Rc<dyn Fn()>>,
}

impl InspectorFieldBatch {
    fn merge<T: Clone + PartialEq + 'static>(
        &mut self,
        extract: impl Fn(&EditorInspectorFieldValue) -> Option<Binding<T>>,
        axis: Option<&str>,
    ) -> Option<Binding<T>> {
        let bindings: Vec<Binding<T>> = self.values.iter().filter_map(&extract).collect();
        if bindings.len() != self.values.len() {
            return None;
        }
        let first = bindings.first()?.clone();
        let first_value = first.get();
        if bindings.iter().any(|binding| binding.get() != first_value) {
            self.is_mixed = true;
            if let Some(axis) = axis {
                self.mixed_axes.insert(axis.to_string());
            }
        }
        {
            let bindings = bindings.clone();
            let next = first_value.clone();
            self.primary_value_setters.push(Rc::new(move || {
                for binding in &bindings {
                    binding.set(next.clone());
                }
            }));
        }
        let get_binding = first.clone();
        let set_bindings = bindings;
        let scene = self.scene.clone();
        let ids = self.ids.clone();
        let section_id = self.section_id.clone();
        let field_id = self.field_id.clone();
        Some(Binding::new(
            move || get_binding.get(),
            move |next: T| {
                let edit_bindings = set_bindings.clone();
                let next = next.clone();
                commit(&scene, &ids, &section_id, &field_id, move || {
                    for binding in &edit_bindings {
                        binding.set(next.clone());
                    }
                });
            },
        ))
    }

    fn can_apply_primary(&self, value: &EditorInspectorFieldValue) -> bool {
        if !self.is_mixed || self.primary_value_setters.is_empty() {
            return false;
        }
        match value {
            EditorInspectorFieldValue::StringOptions { binding, options } => {
                let current = binding.get();
                options.iter().any(|option| option.value == current)
            }
            EditorInspectorFieldValue::EntityReference { binding, options } => {
                let current = binding.get();
                current == 0 || options.iter().any(|option| option.id == current)
            }
            EditorInspectorFieldValue::Asset {
                binding,
                accepted_kinds,
                ..
            } => binding
                .get()
                .map(|asset| accepted_kinds.is_empty() || accepted_kinds.contains(&asset.kind))
                .unwrap_or(true),
            _ => true,
        }
    }

    fn apply_primary_value(&self) {
        let setters = self.primary_value_setters.clone();
        commit(
            &self.scene,
            &self.ids,
            &self.section_id,
            &self.field_id,
            move || {
                for setter in &setters {
                    setter();
                }
            },
        );
    }

    fn value(&mut self) -> Option<EditorInspectorFieldValue> {
        let first = self.values.first()?.clone();
        match first {
            EditorInspectorFieldValue::ReadOnly(first_text) => {
                let mut texts: Vec<String> = Vec::new();
                for value in &self.values {
                    match value {
                        EditorInspectorFieldValue::ReadOnly(text) => texts.push(text.clone()),
                        _ => return None,
                    }
                }
                self.is_mixed = texts.iter().any(|text| *text != first_text);
                Some(EditorInspectorFieldValue::ReadOnly(if self.is_mixed {
                    localized("Mixed value")
                } else {
                    first_text
                }))
            }
            // Actions can delete/reorder attachments; they need their own batch
            // policy. Component actions already provide that separate workflow.
            EditorInspectorFieldValue::Action { .. } => None,
            EditorInspectorFieldValue::Text(_) => {
                let binding: Binding<String> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Text(binding) => Some(binding.clone()),
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::Text(binding))
            }
            EditorInspectorFieldValue::Bool(_) => {
                let binding: Binding<bool> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Bool(binding) => Some(binding.clone()),
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::Bool(binding))
            }
            EditorInspectorFieldValue::Number(_) => {
                let binding: Binding<f32> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Number(binding) => Some(binding.clone()),
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::Number(binding))
            }
            EditorInspectorFieldValue::Color(_) => {
                let binding: Binding<Color> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Color(binding) => Some(binding.clone()),
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::Color(binding))
            }
            EditorInspectorFieldValue::ColliderShapeInstances(_) => {
                let binding: Binding<Vec<ColliderShapeInstance>> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::ColliderShapeInstances(binding) => {
                            Some(binding.clone())
                        }
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::ColliderShapeInstances(binding))
            }
            EditorInspectorFieldValue::ParticleCurve(_) => {
                let binding: Binding<ParticleCurve> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::ParticleCurve(binding) => Some(binding.clone()),
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::ParticleCurve(binding))
            }
            EditorInspectorFieldValue::ParticleSubEmitters(_) => {
                let binding: Binding<Vec<ParticleSubEmitter>> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::ParticleSubEmitters(binding) => {
                            Some(binding.clone())
                        }
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::ParticleSubEmitters(binding))
            }
            EditorInspectorFieldValue::ParticleModuleStack(_) => {
                let binding: Binding<ParticleModuleStack> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::ParticleModuleStack(binding) => {
                            Some(binding.clone())
                        }
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::ParticleModuleStack(binding))
            }
            EditorInspectorFieldValue::ConstrainedNumber {
                step,
                shows_stepper,
                ..
            } => {
                let binding: Binding<f32> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::ConstrainedNumber { binding, .. } => {
                            Some(binding.clone())
                        }
                        _ => None,
                    },
                    None,
                )?;
                let lower = self
                    .values
                    .iter()
                    .filter_map(|value| match value {
                        EditorInspectorFieldValue::ConstrainedNumber { min, .. } => *min,
                        _ => None,
                    })
                    .reduce(f32::max);
                let upper = self
                    .values
                    .iter()
                    .filter_map(|value| match value {
                        EditorInspectorFieldValue::ConstrainedNumber { max, .. } => *max,
                        _ => None,
                    })
                    .reduce(f32::min);
                if let (Some(lower), Some(upper)) = (lower, upper)
                    && lower > upper
                {
                    return None;
                }
                Some(EditorInspectorFieldValue::ConstrainedNumber {
                    binding,
                    min: lower,
                    max: upper,
                    step,
                    shows_stepper,
                })
            }
            EditorInspectorFieldValue::Vector3 { .. } => {
                let x: Binding<f32> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Vector3 { x, .. } => Some(x.clone()),
                        _ => None,
                    },
                    Some("x"),
                )?;
                let y: Binding<f32> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Vector3 { y, .. } => Some(y.clone()),
                        _ => None,
                    },
                    Some("y"),
                )?;
                let z: Binding<f32> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Vector3 { z, .. } => Some(z.clone()),
                        _ => None,
                    },
                    Some("z"),
                )?;
                Some(EditorInspectorFieldValue::Vector3 { x, y, z })
            }
            EditorInspectorFieldValue::StringOptions { options, .. } => {
                let binding: Binding<String> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::StringOptions { binding, .. } => {
                            Some(binding.clone())
                        }
                        _ => None,
                    },
                    None,
                )?;
                let common: Vec<EditorInspectorStringOption> = options
                    .into_iter()
                    .filter(|option| {
                        self.values.iter().all(|value| match value {
                            EditorInspectorFieldValue::StringOptions { options, .. } => {
                                options.contains(option)
                            }
                            _ => false,
                        })
                    })
                    .collect();
                Some(EditorInspectorFieldValue::StringOptions {
                    binding,
                    options: common,
                })
            }
            EditorInspectorFieldValue::EntityReference { options, .. } => {
                let binding: Binding<u64> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::EntityReference { binding, .. } => {
                            Some(binding.clone())
                        }
                        _ => None,
                    },
                    None,
                )?;
                let common: Vec<EditorInspectorEntityOption> = options
                    .into_iter()
                    .filter(|option| {
                        self.values.iter().all(|value| match value {
                            EditorInspectorFieldValue::EntityReference { options, .. } => {
                                options.contains(option)
                            }
                            _ => false,
                        })
                    })
                    .collect();
                Some(EditorInspectorFieldValue::EntityReference {
                    binding,
                    options: common,
                })
            }
            EditorInspectorFieldValue::Json { min_height, .. } => {
                let binding: Binding<String> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Json { binding, .. } => Some(binding.clone()),
                        _ => None,
                    },
                    None,
                )?;
                Some(EditorInspectorFieldValue::Json {
                    binding,
                    min_height,
                })
            }
            EditorInspectorFieldValue::Asset { placeholder, .. } => {
                let binding: Binding<Option<EditorInspectorAssetRef>> = self.merge(
                    |value| match value {
                        EditorInspectorFieldValue::Asset { binding, .. } => Some(binding.clone()),
                        _ => None,
                    },
                    None,
                )?;
                let restrictions: Vec<BTreeSet<String>> = self
                    .values
                    .iter()
                    .filter_map(|value| match value {
                        EditorInspectorFieldValue::Asset { accepted_kinds, .. }
                            if !accepted_kinds.is_empty() =>
                        {
                            Some(accepted_kinds.clone())
                        }
                        _ => None,
                    })
                    .collect();
                let kinds: BTreeSet<String> = restrictions.iter().skip(1).fold(
                    restrictions.first().cloned().unwrap_or_default(),
                    |acc, set| acc.intersection(set).cloned().collect(),
                );
                if !restrictions.is_empty() && kinds.is_empty() {
                    return None;
                }
                Some(EditorInspectorFieldValue::Asset {
                    binding,
                    accepted_kinds: kinds,
                    placeholder,
                })
            }
        }
    }
}

fn commit(
    scene: &EditorSceneAdapter,
    ids: &BTreeSet<u64>,
    section_id: &str,
    field_id: &str,
    edit: impl FnOnce(),
) {
    // Validate the whole selection again at commit time.
    if !scene.is_authoring_enabled() {
        return;
    }
    if !ids
        .iter()
        .all(|id| scene.entity_summary(Some(*id)).is_some() && !scene.is_entity_locked(*id))
    {
        return;
    }
    let fields_present = ids.iter().all(|id| {
        scene
            .inspector_sections(Some(*id))
            .iter()
            .find(|section| section.id == section_id)
            .map(|section| section.fields.iter().any(|field| field.id == field_id))
            .unwrap_or(false)
    });
    if !fields_present {
        return;
    }
    scene.with_edit_history_group(edit);
}
