//! `Editor/Sources/EditorCore/Scene/Adapter/Components.swift`.

use std::collections::BTreeSet;

use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_scene::components::core::registry::ComponentSchema;
use diffuse_scene::components::inspection::inspection::ComponentDescription;
use diffuse_scene::entity_id::EntityID;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;

impl EditorSceneAdapter {
    pub fn component_schema(&self, type_id: &str) -> Option<ComponentSchema> {
        self.scene().component_registry().get(type_id).cloned()
    }

    pub fn component_descriptions(&self, type_id: Option<&str>) -> Vec<ComponentDescription> {
        self.scene().component_descriptions(type_id)
    }

    /// Whether `kind` is currently present on the entity.
    pub fn has_component(&self, kind: &str, on: u64) -> bool {
        let Some(entity) = self.resolve_entity(on) else {
            return false;
        };
        self.scene().has_component_by_type_id(kind, entity)
    }

    pub fn component_type_ids(&self, on: u64) -> Vec<String> {
        self.scene()
            .component_registry()
            .component_schemas()
            .into_iter()
            .filter(|schema| self.has_component(&schema.type_id, on))
            .map(|schema| schema.type_id)
            .collect()
    }

    pub fn addable_component_schemas(&self, on: u64) -> Vec<ComponentSchema> {
        self.scene()
            .component_registry()
            .component_schemas()
            .into_iter()
            .filter(|schema| self.can_add_component(&schema.type_id, on))
            .collect()
    }

    pub fn addable_component_schemas_on_selection(
        &self,
        raw_ids: &BTreeSet<u64>,
    ) -> Vec<ComponentSchema> {
        if raw_ids.is_empty() {
            return Vec::new();
        }
        self.scene()
            .component_registry()
            .component_schemas()
            .into_iter()
            .filter(|schema| {
                raw_ids
                    .iter()
                    .any(|raw_id| self.can_add_component(&schema.type_id, *raw_id))
                    && raw_ids.iter().all(|raw_id| {
                        !self.is_entity_locked(*raw_id)
                            && (self.has_component(&schema.type_id, *raw_id)
                                || self.can_add_component(&schema.type_id, *raw_id))
                    })
            })
            .collect()
    }

    pub fn common_component_schemas(&self, raw_ids: &BTreeSet<u64>) -> Vec<ComponentSchema> {
        if raw_ids.is_empty() {
            return Vec::new();
        }
        self.scene()
            .component_registry()
            .component_schemas()
            .into_iter()
            .filter(|schema| {
                schema.is_user_addable
                    && raw_ids
                        .iter()
                        .all(|raw_id| self.has_component(&schema.type_id, *raw_id))
            })
            .collect()
    }

    /// Adds a default-constructed component of `kind` to the entity. Returns
    /// false if the entity is unknown or already has that component (existing
    /// data is never overwritten).
    pub fn add_component(&self, kind: &str, to: u64) -> bool {
        self.add_component_to_selection(kind, &BTreeSet::from([to]))
    }

    /// Adds the same default component to a complete selection as one history
    /// operation. Validation happens before mutation, so a stale, locked, or
    /// incompatible member rejects the whole request.
    pub fn add_component_to_selection(&self, kind: &str, raw_ids: &BTreeSet<u64>) -> bool {
        let ordered_ids: Vec<u64> = raw_ids.iter().copied().collect();
        let missing_ids: Vec<u64> = ordered_ids
            .iter()
            .copied()
            .filter(|raw_id| !self.has_component(kind, *raw_id))
            .collect();
        if !self.is_authoring_enabled()
            || ordered_ids.is_empty()
            || missing_ids.is_empty()
            || !ordered_ids.iter().all(|raw_id| {
                !self.is_entity_locked(*raw_id)
                    && (self.has_component(kind, *raw_id) || self.can_add_component(kind, *raw_id))
            })
        {
            return false;
        }

        self.install_script_authoring_defaults();
        self.apply_scene_transaction(
            "scene.add_component",
            "Add component",
            ordered_ids,
            missing_ids
                .iter()
                .map(|raw_id| SceneMutation::AddComponent {
                    entity_id: *raw_id,
                    type_id: kind.to_string(),
                })
                .collect(),
        )
        .is_some()
    }

    fn can_add_component(&self, kind: &str, to: u64) -> bool {
        let Some(entity) = self.resolve_entity(to) else {
            return false;
        };
        if self.has_component(kind, to) {
            return false;
        }
        let scene = self.scene();
        let Some(schema) = scene.component_registry().get(kind) else {
            return false;
        };
        if !schema.is_user_addable {
            return false;
        }
        let _ = entity;
        !schema
            .incompatible_with
            .iter()
            .any(|incompatible| self.has_component(incompatible, to))
    }

    /// Removes `kind` from the entity. Returns false if the entity is unknown or
    /// did not carry that component.
    pub fn remove_component(&self, kind: &str, from: u64) -> bool {
        self.remove_component_from_selection(kind, &BTreeSet::from([from]))
    }

    /// Removes a component from every selected entity as a single undo step.
    /// Every target must contain the component and be editable before any
    /// mutation is applied.
    pub fn remove_component_from_selection(&self, kind: &str, raw_ids: &BTreeSet<u64>) -> bool {
        let ordered_ids: Vec<u64> = raw_ids.iter().copied().collect();
        if !self.is_authoring_enabled()
            || ordered_ids.is_empty()
            || !ordered_ids.iter().all(|raw_id| {
                !self.is_entity_locked(*raw_id)
                    && self.resolve_entity(*raw_id).is_some()
                    && self.has_component(kind, *raw_id)
            })
        {
            return false;
        }
        self.apply_scene_transaction(
            "scene.remove_component_data",
            "Remove component",
            ordered_ids.clone(),
            ordered_ids
                .iter()
                .map(|raw_id| SceneMutation::RemoveComponentData {
                    entity_id: *raw_id,
                    type_id: kind.to_string(),
                })
                .collect(),
        )
        .is_some()
    }

    /// Restores the selected component to its engine default on every target.
    /// Reset is deliberately atomic and undoable because it can discard many
    /// authored fields at once.
    pub fn reset_component(&self, kind: &str, on: &BTreeSet<u64>) -> bool {
        let ordered_ids: Vec<u64> = on.iter().copied().collect();
        if !self.is_authoring_enabled()
            || ordered_ids.is_empty()
            || !ordered_ids.iter().all(|raw_id| {
                !self.is_entity_locked(*raw_id)
                    && self.resolve_entity(*raw_id).is_some()
                    && self.has_component(kind, *raw_id)
            })
        {
            return false;
        }
        self.install_script_authoring_defaults();
        let mutations: Vec<SceneMutation> = ordered_ids
            .iter()
            .flat_map(|raw_id| {
                [
                    SceneMutation::RemoveComponentData {
                        entity_id: *raw_id,
                        type_id: kind.to_string(),
                    },
                    SceneMutation::AddComponent {
                        entity_id: *raw_id,
                        type_id: kind.to_string(),
                    },
                ]
            })
            .collect();
        self.apply_scene_transaction(
            "scene.reset_component",
            "Reset component",
            ordered_ids,
            mutations,
        )
        .is_some()
    }

    /// Swift's single-entity overload of `resetComponent`.
    pub fn reset_component_on_entity(&self, kind: &str, on: u64) -> bool {
        self.reset_component(kind, &BTreeSet::from([on]))
    }

    fn resolve_entity(&self, raw_id: u64) -> Option<EntityID> {
        let entity = EntityID::new(raw_id as u32, (raw_id >> 32) as u32);
        self.scene().contains(entity).then_some(entity)
    }
}
