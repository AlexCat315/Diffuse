//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Physics/Destruction.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::destruction::{Destructible, DestructibleAssetResource};

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};

#[derive(Clone, Copy)]
enum DestructibleFloatField {
    DamageThreshold,
    ImpulseThreshold,
    MaximumFragmentLifetimeSeconds,
    SleepingRecycleDelaySeconds,
    SeparationImpulse,
}

impl EditorSceneAdapter {
    pub(crate) fn destructible_section(&self, entity: EntityID) -> Option<EditorInspectorSection> {
        if !self.scene().has_component::<Destructible>(entity) {
            return None;
        }
        let authored = self.scene().component::<Destructible>(entity);
        let asset = authored.as_ref().and_then(|authored| {
            self.scene()
                .resource::<DestructibleAssetResource>()
                .and_then(|resource| resource.asset(&authored.asset_resource_id).cloned())
        });
        let state = self
            .scene()
            .destruction_state_frame()
            .sources
            .get(&entity)
            .cloned();
        let fields: Vec<EditorInspectorField> = vec![
            EditorInspectorField::new(
                "destructible-enabled",
                localized("Enabled"),
                EditorInspectorFieldValue::Bool(self.destructible_bool_binding(entity)),
            ),
            EditorInspectorField::new(
                "destructible-asset",
                localized("Pre-fractured Asset"),
                EditorInspectorFieldValue::Text(self.destructible_asset_binding(entity)),
            ),
            constrained(
                "destructible-damage-threshold",
                "Damage Threshold",
                self.destructible_float_binding(entity, DestructibleFloatField::DamageThreshold),
                1.0,
            ),
            constrained(
                "destructible-impulse-threshold",
                "Impulse Threshold",
                self.destructible_float_binding(entity, DestructibleFloatField::ImpulseThreshold),
                1.0,
            ),
            constrained(
                "destructible-fragment-budget",
                "Fragment Budget",
                self.destructible_budget_binding(entity),
                1.0,
            ),
            constrained(
                "destructible-lifetime",
                "Maximum Lifetime",
                self.destructible_float_binding(
                    entity,
                    DestructibleFloatField::MaximumFragmentLifetimeSeconds,
                ),
                1.0,
            ),
            constrained(
                "destructible-sleep-recycle",
                "Sleeping Recycle Delay",
                self.destructible_float_binding(
                    entity,
                    DestructibleFloatField::SleepingRecycleDelaySeconds,
                ),
                0.5,
            ),
            constrained(
                "destructible-separation-impulse",
                "Separation Impulse",
                self.destructible_float_binding(entity, DestructibleFloatField::SeparationImpulse),
                0.05,
            ),
            EditorInspectorField::new(
                "destructible-asset-fragments",
                localized("Asset Fragments"),
                EditorInspectorFieldValue::ReadOnly(
                    asset
                        .as_ref()
                        .map(|asset| asset.fragments.len())
                        .unwrap_or(0)
                        .to_string(),
                ),
            ),
            EditorInspectorField::new(
                "destructible-asset-connections",
                localized("Asset Connections"),
                EditorInspectorFieldValue::ReadOnly(
                    asset
                        .as_ref()
                        .map(|asset| asset.connections.len())
                        .unwrap_or(0)
                        .to_string(),
                ),
            ),
            EditorInspectorField::new(
                "destructible-active-fragments",
                localized("Active Fragments"),
                EditorInspectorFieldValue::ReadOnly(
                    state
                        .as_ref()
                        .map(|state| state.active_fragment_entities.len())
                        .unwrap_or(0)
                        .to_string(),
                ),
            ),
            EditorInspectorField::new(
                "destructible-retained-fragments",
                localized("Retained Fragments"),
                EditorInspectorFieldValue::ReadOnly(
                    state
                        .as_ref()
                        .map(|state| state.retained_fragment_ids.len())
                        .unwrap_or(0)
                        .to_string(),
                ),
            ),
            EditorInspectorField::new(
                "destructible-released-fragments",
                localized("Released Fragments"),
                EditorInspectorFieldValue::ReadOnly(
                    state
                        .as_ref()
                        .map(|state| state.released_fragment_ids.len())
                        .unwrap_or(0)
                        .to_string(),
                ),
            ),
            EditorInspectorField::new(
                "destructible-fracture-state",
                localized("Fracture State"),
                EditorInspectorFieldValue::ReadOnly(match state.as_ref() {
                    Some(state) if state.is_fully_fractured => localized("Fully Fractured"),
                    Some(state) if state.has_fractured => localized("Partially Fractured"),
                    _ => localized("Intact"),
                }),
            ),
            EditorInspectorField::new(
                "destructible-broken-connections",
                localized("Broken Connections"),
                EditorInspectorFieldValue::ReadOnly(
                    state
                        .as_ref()
                        .map(|state| state.broken_connection_ids.len())
                        .unwrap_or(0)
                        .to_string(),
                ),
            ),
        ];
        Some(EditorInspectorSection::new(
            "destructible",
            localized("Destructible"),
            fields,
        ))
    }

    fn destructible_asset_binding(&self, entity: EntityID) -> Binding<String> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Destructible>(entity)
                    .map(|destructible| destructible.asset_resource_id)
                    .unwrap_or_default()
            },
            move |value: String| {
                let _ = set_adapter.update_component_data::<Destructible>(entity, |destructible| {
                    destructible.asset_resource_id = value.clone();
                });
            },
        )
    }

    fn destructible_float_binding(
        &self,
        entity: EntityID,
        field: DestructibleFloatField,
    ) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Destructible>(entity)
                    .map(|destructible| destructible_float(&destructible, field))
                    .unwrap_or(0.0)
            },
            move |value: f32| {
                if !value.is_finite() {
                    return;
                }
                let _ = set_adapter.update_component_data::<Destructible>(entity, |destructible| {
                    set_destructible_float(destructible, field, value.max(0.0));
                });
            },
        )
    }

    fn destructible_bool_binding(&self, entity: EntityID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Destructible>(entity)
                    .map(|destructible| destructible.is_enabled)
                    .unwrap_or(false)
            },
            move |value: bool| {
                let _ = set_adapter.update_component_data::<Destructible>(entity, |destructible| {
                    destructible.is_enabled = value;
                });
            },
        )
    }

    fn destructible_budget_binding(&self, entity: EntityID) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Destructible>(entity)
                    .map(|destructible| destructible.fragment_budget as f32)
                    .unwrap_or(0.0)
            },
            move |value: f32| {
                if !value.is_finite() {
                    return;
                }
                let rounded = value.round();
                let rounded_f64 = f64::from(rounded);
                let budget = (rounded_f64 >= i64::MIN as f64 && rounded_f64 <= i64::MAX as f64)
                    .then_some(rounded_f64 as i64)
                    .map(|value| value.max(0))
                    .unwrap_or_else(|| if rounded > 0.0 { i64::MAX } else { 0 });
                let _ = set_adapter.update_component_data::<Destructible>(entity, |destructible| {
                    destructible.fragment_budget = budget;
                });
            },
        )
    }
}

fn constrained(id: &str, label: &str, binding: Binding<f32>, step: f32) -> EditorInspectorField {
    EditorInspectorField::new(
        id,
        localized(label),
        EditorInspectorFieldValue::ConstrainedNumber {
            binding,
            min: Some(0.0),
            max: None,
            step: Some(step),
            shows_stepper: true,
        },
    )
}

fn destructible_float(destructible: &Destructible, field: DestructibleFloatField) -> f32 {
    match field {
        DestructibleFloatField::DamageThreshold => destructible.damage_threshold,
        DestructibleFloatField::ImpulseThreshold => destructible.impulse_threshold,
        DestructibleFloatField::MaximumFragmentLifetimeSeconds => {
            destructible.maximum_fragment_lifetime_seconds
        }
        DestructibleFloatField::SleepingRecycleDelaySeconds => {
            destructible.sleeping_recycle_delay_seconds
        }
        DestructibleFloatField::SeparationImpulse => destructible.separation_impulse,
    }
}

fn set_destructible_float(
    destructible: &mut Destructible,
    field: DestructibleFloatField,
    value: f32,
) {
    match field {
        DestructibleFloatField::DamageThreshold => destructible.damage_threshold = value,
        DestructibleFloatField::ImpulseThreshold => destructible.impulse_threshold = value,
        DestructibleFloatField::MaximumFragmentLifetimeSeconds => {
            destructible.maximum_fragment_lifetime_seconds = value
        }
        DestructibleFloatField::SleepingRecycleDelaySeconds => {
            destructible.sleeping_recycle_delay_seconds = value
        }
        DestructibleFloatField::SeparationImpulse => destructible.separation_impulse = value,
    }
}
