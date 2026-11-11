//! `Editor/Sources/EditorCore/Scene/Adapter/EntityQueries.swift`.

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::collider::Collider;
use diffuse_scene::physics::collider::ColliderShape;
use diffuse_scene::physics::destruction::Destructible;
use diffuse_scene::physics::joints::physics_joint::Constraint;
use diffuse_scene::physics::ragdoll::Ragdoll;
use diffuse_scene::physics::rigid_body::RigidBody;
use diffuse_scene::physics::vehicles::vehicle::Vehicle;
use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
use diffuse_script::ScriptComponent;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::models::editor_scene_node::EditorSceneEntitySummary;

impl EditorSceneAdapter {
    pub fn entity_summary(&self, id: Option<u64>) -> Option<EditorSceneEntitySummary> {
        let entity = self.entity_from(id)?;
        let scene = self.scene();
        if !scene.contains(entity) {
            return None;
        }
        Some(EditorSceneEntitySummary::new(
            entity.raw_value(),
            self.display_name(entity),
            self.display_kind(entity),
        ))
    }

    pub fn display_name(&self, entity: EntityID) -> String {
        self.scene()
            .component::<SceneNameComponent>(entity)
            .map(|component| component.value)
            .unwrap_or_else(|| self.fallback_name(entity))
    }

    pub fn display_kind(&self, entity: EntityID) -> String {
        let scene = self.scene();
        if let Some(kind) = scene
            .component::<SceneKindComponent>(entity)
            .map(|component| component.value)
        {
            return kind;
        }
        if scene.has_component::<Constraint>(entity) {
            return "Constraint".to_string();
        }
        if scene.has_component::<Ragdoll>(entity) {
            return "Ragdoll".to_string();
        }
        if scene.has_component::<Vehicle>(entity) {
            return "Vehicle".to_string();
        }
        if scene.has_component::<Destructible>(entity) {
            return "Destructible".to_string();
        }
        if scene.has_component::<RigidBody>(entity) || scene.has_component::<Collider>(entity) {
            return "Physics Entity".to_string();
        }
        if scene.has_component::<ScriptComponent>(entity) {
            return "Scripted Entity".to_string();
        }
        "Entity".to_string()
    }

    pub fn fallback_name(&self, entity: EntityID) -> String {
        format!("Entity {}", entity.index)
    }

    pub fn manifest_mesh_collider_resource_id(&self, mesh_index: i64) -> String {
        format!("meshIndex:{mesh_index}")
    }

    fn describe(&self, shape: &ColliderShape) -> String {
        match shape {
            ColliderShape::Box { half_extents, .. } => {
                format!("Box {}", self.format_vector(*half_extents * 2.0))
            }
            ColliderShape::Sphere { radius, .. } => format!("Sphere r={}", self.format(*radius)),
            ColliderShape::Capsule {
                radius,
                half_height,
                ..
            } => format!(
                "Capsule r={} h={}",
                self.format(*radius),
                self.format(half_height * 2.0)
            ),
            ColliderShape::Cylinder {
                radius,
                half_height,
                ..
            } => format!(
                "Cylinder r={} h={}",
                self.format(*radius),
                self.format(half_height * 2.0)
            ),
            ColliderShape::HeightField { resource_id, .. } => resource_id
                .as_ref()
                .map(|id| format!("HeightField {id}"))
                .unwrap_or_else(|| "HeightField".to_string()),
            ColliderShape::Mesh { resource_id, .. } => resource_id
                .as_ref()
                .map(|id| format!("Mesh {id}"))
                .unwrap_or_else(|| "Mesh".to_string()),
            ColliderShape::Convex { resource_id, .. } => resource_id
                .as_ref()
                .map(|id| format!("Convex {id}"))
                .unwrap_or_else(|| "Convex".to_string()),
        }
    }

    pub(crate) fn format_vector(&self, value: Float3) -> String {
        format!(
            "{}, {}, {}",
            self.format(value.x),
            self.format(value.y),
            self.format(value.z)
        )
    }

    pub(crate) fn format(&self, value: f32) -> String {
        format!("{value:.2}")
    }

    pub fn entity_from(&self, raw_id: Option<u64>) -> Option<EntityID> {
        raw_id.map(EntityID::from_raw_value)
    }
}
