//! `Editor/Sources/EditorCore/Scene/Adapter/Hierarchy.swift`.

use std::collections::BTreeSet;

use diffuse_intent::transactions::transaction_executor::TransactionApplyResult;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_extraction::RenderMeshComponent;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::models::editor_hierarchy_lock_component::EditorHierarchyLockComponent;
use crate::scene::models::editor_scene_node::EditorSceneNode;

impl EditorSceneAdapter {
    pub fn roots(&self) -> Vec<EditorSceneNode> {
        let scene = self.scene();
        scene
            .roots()
            .into_iter()
            .map(|entity| self.build_node(entity))
            .collect()
    }

    pub fn move_entity(
        &self,
        entity_id: u64,
        parent_id: Option<u64>,
        index: i64,
    ) -> Option<TransactionApplyResult> {
        let mut targets = vec![entity_id];
        if let Some(parent_id) = parent_id {
            targets.push(parent_id);
        }
        self.apply_scene_transaction(
            "scene.move_entity",
            "Move entity in hierarchy",
            targets,
            vec![SceneMutation::MoveEntity {
                entity_id,
                parent_id,
                index,
            }],
        )
    }

    /// Moves the top-level members of a hierarchy selection to the scene root
    /// as one undoable transaction. Selected descendants are intentionally
    /// omitted because moving their selected ancestor already preserves them.
    pub fn move_entities_to_root(&self, entity_ids: &BTreeSet<u64>) -> bool {
        let scene = self.scene();
        let existing_ids: BTreeSet<u64> = entity_ids
            .iter()
            .copied()
            .filter(|raw_id| {
                self.entity_from(Some(*raw_id))
                    .map(|entity| scene.contains(entity))
                    .unwrap_or(false)
            })
            .collect();
        if existing_ids.len() != entity_ids.len() || existing_ids.is_empty() {
            return false;
        }

        // Preserve the hierarchy's visible depth-first order. Sorting entity
        // IDs is not a stable proxy for scene order after the user has
        // reordered siblings or moved entities between parents.
        fn collect(
            scene: &diffuse_scene::scene_runtime::SceneRuntime,
            entity: EntityID,
            has_selected_ancestor: bool,
            existing_ids: &BTreeSet<u64>,
            nested_ids: &mut Vec<u64>,
        ) {
            let raw_id = entity.raw_value();
            let is_selected = existing_ids.contains(&raw_id);
            if is_selected && !has_selected_ancestor && scene.parent(entity).is_some() {
                nested_ids.push(raw_id);
            }
            for child in scene.children(entity) {
                collect(
                    scene,
                    child,
                    has_selected_ancestor || is_selected,
                    existing_ids,
                    nested_ids,
                );
            }
        }

        let mut nested_ids: Vec<u64> = Vec::new();
        for root in scene.roots() {
            collect(&scene, root, false, &existing_ids, &mut nested_ids);
        }
        if nested_ids.is_empty() {
            return false;
        }
        let start_index = scene.roots().len() as i64;
        let mutations: Vec<SceneMutation> = nested_ids
            .iter()
            .enumerate()
            .map(|(offset, raw_id)| SceneMutation::MoveEntity {
                entity_id: *raw_id,
                parent_id: None,
                index: start_index + offset as i64,
            })
            .collect();
        self.apply_scene_transaction(
            "scene.move_entities_to_root",
            if nested_ids.len() == 1 {
                "Move entity to root"
            } else {
                "Move entities to root"
            },
            nested_ids,
            mutations,
        )
        .is_some()
    }

    /// Renames one entity through the same transactional path used by the
    /// Inspector. Empty names are rejected so inline rename can keep the draft
    /// visible and explain the error instead of silently substituting a name.
    pub fn rename_entity(&self, raw_id: u64, proposed_name: &str) -> bool {
        let trimmed = proposed_name.trim();
        let Some(entity) = self.entity_from(Some(raw_id)) else {
            return false;
        };
        let scene = self.scene();
        if trimmed.is_empty() || !scene.contains(entity) {
            return false;
        }
        let current = scene
            .component::<diffuse_scene::scene_bootstrap::SceneNameComponent>(entity)
            .map(|component| component.value)
            .unwrap_or_else(|| self.fallback_name(entity));
        if current == trimmed {
            return true;
        }
        self.apply_scene_transaction(
            "scene.set_name",
            "Rename entity",
            vec![raw_id],
            vec![SceneMutation::SetSceneName {
                entity_id: raw_id,
                value: trimmed.to_string(),
            }],
        )
        .is_some()
    }

    pub fn set_hierarchy_visibility(&self, is_visible: bool, entity_ids: &BTreeSet<u64>) -> bool {
        let scene = self.scene();
        fn collect(
            scene: &diffuse_scene::scene_runtime::SceneRuntime,
            entity: EntityID,
            renderable_ids: &mut BTreeSet<u64>,
        ) {
            if scene.has_component::<RenderMeshComponent>(entity) {
                renderable_ids.insert(entity.raw_value());
            }
            for child in scene.children(entity) {
                collect(scene, child, renderable_ids);
            }
        }
        let mut renderable_ids: BTreeSet<u64> = BTreeSet::new();
        for raw_id in entity_ids {
            let Some(entity) = self.entity_from(Some(*raw_id)) else {
                continue;
            };
            if !scene.contains(entity) {
                continue;
            }
            collect(&scene, entity, &mut renderable_ids);
        }
        let mutations: Vec<SceneMutation> = renderable_ids
            .iter()
            .filter_map(|raw_id| {
                let entity = self.entity_from(Some(*raw_id))?;
                let mesh = scene.component::<RenderMeshComponent>(entity)?;
                if mesh.is_visible == is_visible {
                    return None;
                }
                Some(SceneMutation::component_fields(
                    *raw_id,
                    "renderMesh",
                    [(
                        "isVisible".to_string(),
                        Some(ComponentValue::Bool(is_visible)),
                    )],
                ))
            })
            .collect();
        if mutations.is_empty() {
            return false;
        }
        self.apply_scene_transaction(
            "scene.set_hierarchy_visibility",
            if is_visible {
                "Show hierarchy entities"
            } else {
                "Hide hierarchy entities"
            },
            renderable_ids.iter().copied().collect(),
            mutations,
        )
        .is_some()
    }

    pub fn is_hierarchy_visible(&self, raw_id: u64) -> bool {
        let Some(root) = self.entity_from(Some(raw_id)) else {
            return true;
        };
        let scene = self.scene();
        if !scene.contains(root) {
            return true;
        }
        fn collect(
            scene: &diffuse_scene::scene_runtime::SceneRuntime,
            entity: EntityID,
            visibility: &mut Vec<bool>,
        ) {
            if let Some(mesh) = scene.component::<RenderMeshComponent>(entity) {
                visibility.push(mesh.is_visible);
            }
            for child in scene.children(entity) {
                collect(scene, child, visibility);
            }
        }
        let mut visibility: Vec<bool> = Vec::new();
        collect(&scene, root, &mut visibility);
        visibility.iter().all(|visible| *visible)
    }

    pub fn hierarchy_has_renderable_content(&self, raw_id: u64) -> bool {
        let Some(root) = self.entity_from(Some(raw_id)) else {
            return false;
        };
        let scene = self.scene();
        if !scene.contains(root) {
            return false;
        }
        fn contains_renderable(
            scene: &diffuse_scene::scene_runtime::SceneRuntime,
            entity: EntityID,
        ) -> bool {
            if scene.has_component::<RenderMeshComponent>(entity) {
                return true;
            }
            scene
                .children(entity)
                .into_iter()
                .any(|child| contains_renderable(scene, child))
        }
        contains_renderable(&scene, root)
    }

    pub fn set_entity_locked(&self, is_locked: bool, entity_ids: &BTreeSet<u64>) {
        if !self.is_authoring_enabled() {
            self.notify_transaction_error("Stop simulation before changing hierarchy locks");
            return;
        }
        let mut changed = false;
        for raw_id in entity_ids {
            let Some(entity) = self.entity_from(Some(*raw_id)) else {
                continue;
            };
            {
                let mut outcome = false;
                self.with_scene_mut(|scene| {
                    if !scene.contains(entity) {
                        return;
                    }
                    let was_locked = scene.has_component::<EditorHierarchyLockComponent>(entity);
                    if was_locked == is_locked {
                        return;
                    }
                    outcome = if is_locked {
                        scene.set_component(EditorHierarchyLockComponent, entity)
                    } else {
                        scene
                            .remove_component::<EditorHierarchyLockComponent>(entity)
                            .is_some()
                    };
                });
                changed = changed || outcome;
            }
        }
        if changed {
            self.notify_revision_changed_default();
        }
    }

    pub fn is_entity_locked(&self, raw_id: u64) -> bool {
        let Some(entity) = self.entity_from(Some(raw_id)) else {
            return false;
        };
        let scene = self.scene();
        scene.contains(entity) && scene.has_component::<EditorHierarchyLockComponent>(entity)
    }

    fn build_node(&self, entity: EntityID) -> EditorSceneNode {
        let scene = self.scene();
        EditorSceneNode::new(
            entity.raw_value(),
            self.display_name(entity),
            self.display_kind(entity),
            scene
                .children(entity)
                .into_iter()
                .map(|child| self.build_node(child))
                .collect(),
        )
    }
}
