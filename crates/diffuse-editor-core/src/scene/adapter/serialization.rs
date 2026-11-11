//! `Editor/Sources/EditorCore/Scene/Adapter/Serialization.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_scene::components::core::registry::{ComponentDecodeContext, ComponentEncodeContext};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::input_action::InputActionMap;
use diffuse_scene::physics::collider::{Collider, ColliderShape, SpatialAABB};
use diffuse_scene::physics::queries::spatial_queries::{
    MeshColliderBoundsResource, MeshColliderGeometry, MeshColliderGeometryResource,
};
use diffuse_scene::physics::soft_bodies::soft_body::SoftBodyMesh;
use diffuse_scene::rendering::render_extraction::RenderMeshComponent;
use diffuse_scene::scene_bootstrap::{
    AssetReferenceComponent, SceneKindComponent, SceneNameComponent,
};
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_scene::serialization::scene_serializer::SceneSerializer;
use diffuse_script::input::default_input_actions::DefaultInputActions;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::manifest::editor_scene_manifest::{
    EditorSceneManifest, EditorSceneManifestLoadError, EditorSceneManifestLoadResult,
};
use crate::scene::manifest::node::EditorSceneManifestNode;
use crate::scene::manifest::settings::{
    EditorSceneManifestParticleScalability, EditorSceneManifestParticleScalabilityPolicy,
    EditorSceneManifestPhysicsSettings,
};
use crate::scene::manifest::transform_math::EditorSceneManifestMatrix;
use crate::scene::models::editor_hierarchy_lock_component::EditorHierarchyLockComponent;

impl EditorSceneAdapter {
    /// Swift's `selectedEntityID: UInt64? = nil` default.
    pub fn manifest(&self) -> EditorSceneManifest {
        self.manifest_for_selection(None)
    }

    pub fn manifest_for_selection(&self, selected_entity_id: Option<u64>) -> EditorSceneManifest {
        let scene = self.scene();
        let selected_entity = self.entity_from(selected_entity_id);
        let restored_selection = selected_entity
            .filter(|entity| scene.contains(*entity))
            .map(|entity| entity.raw_value());
        let physics_settings = scene
            .resource::<diffuse_scene::physics::physics_settings::PhysicsSettingsResource>()
            .map(|settings| EditorSceneManifestPhysicsSettings::new(&settings));
        let particle_scalability = scene
            .resource::<diffuse_scene::particles::particle_scalability::ParticleScalabilityResource>()
            .map(|settings| EditorSceneManifestParticleScalability::new(&settings));
        let particle_scalability_policy = scene
            .resource::<diffuse_scene::particles::particle_scalability::ParticleScalabilityPolicyResource>()
            .map(|policy| EditorSceneManifestParticleScalabilityPolicy::new(&policy));
        let scene_kind = scene
            .resource::<SceneKindComponent>()
            .map(|component| component.value);
        let asset_registry = AssetRegistry::shared();
        let asset_count = asset_registry.entries_snapshot().len();
        let timestamp = iso8601_now();

        let mut ordered: Vec<EntityID> = Vec::new();
        fn visit(scene: &SceneRuntime, entity: EntityID, ordered: &mut Vec<EntityID>) {
            ordered.push(entity);
            for child in scene.children(entity) {
                visit(scene, child, ordered);
            }
        }
        for root in scene.roots() {
            visit(&scene, root, &mut ordered);
        }
        let mut context = ComponentEncodeContext::new(
            ordered
                .iter()
                .enumerate()
                .map(|(index, entity)| (*entity, index as i64))
                .collect(),
        );
        let manifest_roots: Vec<EditorSceneManifestNode> = scene
            .roots()
            .into_iter()
            .map(|root| self.manifest_node(root, &mut context))
            .collect();
        let locked_entities: Vec<u64> = scene
            .entities_with::<EditorHierarchyLockComponent>()
            .into_iter()
            .map(|entity| entity.raw_value())
            .collect();
        let mut locked: Vec<u64> = locked_entities;
        locked.sort_unstable();
        EditorSceneManifest::with_options(
            EditorSceneManifest::CURRENT_SCHEMA_VERSION,
            self.revision(),
            self.entity_count() as i64,
            restored_selection,
            scene_kind,
            physics_settings,
            particle_scalability,
            particle_scalability_policy,
            if asset_count > 0 {
                Some(asset_count as i64)
            } else {
                None
            },
            Some(timestamp),
            if locked.is_empty() {
                None
            } else {
                Some(locked)
            },
            manifest_roots,
        )
    }

    /// Swift's `notify: Bool = true` default.
    pub fn load(&self, manifest: &EditorSceneManifest) -> EditorSceneManifestLoadResult {
        self.load_with_notify(manifest, true)
    }

    pub fn load_with_notify(
        &self,
        manifest: &EditorSceneManifest,
        notify: bool,
    ) -> EditorSceneManifestLoadResult {
        if manifest.schema_version != EditorSceneManifest::CURRENT_SCHEMA_VERSION {
            return EditorSceneManifestLoadResult::with_error(
                self.entity_count() as i64,
                self.default_selection_id(),
                Some(EditorSceneManifestLoadError::UnsupportedVersion(
                    manifest.schema_version,
                )),
            );
        }
        let registry = self.scene().component_registry().clone();
        let mut restored_scene = SceneRuntime::new(registry);
        let mut id_map: BTreeMap<u64, EntityID> = BTreeMap::new();
        let mut ordered_nodes: Vec<EditorSceneManifestNode> = Vec::new();

        fn restore_node(
            scene: &mut SceneRuntime,
            node: &EditorSceneManifestNode,
            id_map: &mut BTreeMap<u64, EntityID>,
            ordered_nodes: &mut Vec<EditorSceneManifestNode>,
        ) -> EntityID {
            let entity = scene.create_entity();
            id_map.insert(node.id, entity);
            let _ = scene.set_component(SceneNameComponent::new(node.name.clone()), entity);
            let _ = scene.set_component(SceneKindComponent::new(node.kind.clone()), entity);
            let transform = node
                .local_transform
                .as_ref()
                .and_then(|matrix| matrix.local_transform())
                .unwrap_or(diffuse_scene::runtime_world::LocalTransform::IDENTITY);
            let _ = scene.set_local_transform(transform, entity);
            ordered_nodes.push(node.clone());
            for child in &node.children {
                let child_entity = restore_node(scene, child, id_map, ordered_nodes);
                let _ = scene.set_parent(Some(entity), child_entity);
            }
            entity
        }

        for root in &manifest.roots {
            restore_node(&mut restored_scene, root, &mut id_map, &mut ordered_nodes);
        }
        let entity_map: BTreeMap<i64, EntityID> = ordered_nodes
            .iter()
            .enumerate()
            .filter_map(|(index, node)| id_map.get(&node.id).map(|entity| (index as i64, *entity)))
            .collect();
        for node in &ordered_nodes {
            let Some(entity) = id_map.get(&node.id) else {
                continue;
            };
            let mut context = ComponentDecodeContext::new(entity_map.clone());
            SceneSerializer::apply_component_document(
                restored_scene.world_mut(),
                *entity,
                &node.components,
                &mut context,
            );
        }
        for root in &manifest.roots {
            refresh_asset_references(&mut restored_scene, root, &id_map);
        }
        if let Some(physics_settings) = &manifest.physics_settings {
            restored_scene.set_resource(physics_settings.settings());
        }
        if let Some(particle_scalability) = &manifest.particle_scalability {
            restored_scene.set_resource(particle_scalability.settings());
        }
        if let Some(particle_scalability_policy) = &manifest.particle_scalability_policy {
            restored_scene.set_resource(particle_scalability_policy.policy());
        }
        restored_scene.set_resource(<InputActionMap as DefaultInputActions>::cove_default());
        if let Some(locked_ids) = &manifest.locked_entity_ids {
            for original_id in locked_ids {
                if let Some(entity) = id_map.get(original_id) {
                    let _ = restored_scene.set_component(EditorHierarchyLockComponent, *entity);
                }
            }
        }
        self.rebuild_mesh_collider_resources(&mut restored_scene);
        restored_scene.propagate_transforms();

        self.script_runtime.reset();
        self.set_scene(restored_scene);
        self.invalidate_particle_feedback();
        let root_ids: Vec<u64> = self
            .scene()
            .roots()
            .into_iter()
            .map(|entity| entity.raw_value())
            .collect();
        let selected = manifest
            .selected_entity_id
            .and_then(|id| id_map.get(&id).map(|entity| entity.raw_value()))
            .or_else(|| root_ids.first().copied());
        self.initial_selection_id.set(selected);
        *self.initial_expanded_ids.borrow_mut() = root_ids.into_iter().collect();
        self.reset_edit_history();
        if notify {
            self.notify_revision_changed(false, None);
        }
        EditorSceneManifestLoadResult::new(self.entity_count() as i64, selected)
    }

    fn manifest_node(
        &self,
        entity: EntityID,
        context: &mut ComponentEncodeContext,
    ) -> EditorSceneManifestNode {
        let scene = self.scene();
        let local_transform = scene
            .local_transform(entity)
            .map(|transform| EditorSceneManifestMatrix::from_matrix(&transform.matrix));
        let components = SceneSerializer::component_document(scene.world(), entity, context);
        let children: Vec<EditorSceneManifestNode> = scene
            .children(entity)
            .into_iter()
            .map(|child| self.manifest_node(child, context))
            .collect();
        EditorSceneManifestNode::with_options(
            entity.raw_value(),
            self.display_name(entity),
            self.display_kind(entity),
            local_transform,
            components,
            children,
        )
    }

    /// Derived collision geometry follows an edited asset in every history
    /// snapshot, so undoing a transform cannot resurrect an obsolete collider.
    pub fn refresh_asset_geometry(&self) {
        let mut scene = self.scene();
        self.rebuild_mesh_collider_resources(&mut scene);
        self.set_scene(scene);
        let mut history = self.edit_history.borrow_mut();
        history.remap_scenes(|runtime| self.rebuild_mesh_collider_resources(runtime));
        drop(history);
        self.notify_revision_changed(false, None);
    }

    fn rebuild_mesh_collider_resources(&self, runtime: &mut SceneRuntime) {
        let mut bounds_resource: MeshColliderBoundsResource = runtime
            .resource::<MeshColliderBoundsResource>()
            .unwrap_or_else(|| MeshColliderBoundsResource::new(BTreeMap::new(), None));
        let mut geometry_resource: MeshColliderGeometryResource = runtime
            .resource::<MeshColliderGeometryResource>()
            .unwrap_or_else(|| MeshColliderGeometryResource::new(BTreeMap::new(), None));
        let mut changed_bounds = false;
        let mut changed_geometry = false;
        let registry = AssetRegistry::shared();

        for entity in runtime.entities() {
            let Some(asset) = runtime.component::<AssetReferenceComponent>(entity) else {
                continue;
            };
            let Some(mesh) = registry.mesh_asset(asset.mesh_index) else {
                continue;
            };
            let mut resource_ids: BTreeSet<String> = BTreeSet::new();
            if let Some(collider) = runtime.component::<Collider>(entity)
                && let ColliderShape::Mesh { resource_id, .. } = collider.shape()
            {
                resource_ids.insert(
                    resource_id.clone().unwrap_or_else(|| {
                        self.manifest_mesh_collider_resource_id(asset.mesh_index)
                    }),
                );
            }
            if let Some(soft_body_mesh) = runtime.component::<SoftBodyMesh>(entity) {
                let resource_id = soft_body_mesh
                    .resource_id
                    .clone()
                    .unwrap_or_else(|| self.manifest_mesh_collider_resource_id(asset.mesh_index));
                resource_ids.insert(resource_id.clone());
                if soft_body_mesh.resource_id.is_none() {
                    let mut resolved = soft_body_mesh;
                    resolved.resource_id = Some(resource_id);
                    let _ = runtime.set_component(resolved, entity);
                }
            }
            if resource_ids.is_empty() {
                continue;
            }
            let (local_min, local_max) = mesh.local_bounds();
            let bounds = SpatialAABB::new(local_min, local_max);
            let geometry = MeshColliderGeometry::new(
                (0..mesh.vertex_count() as i64)
                    .filter_map(|index| mesh.position(index))
                    .collect(),
                mesh.indices.clone(),
                Vec::new(),
                (0..mesh.vertex_count() as i64)
                    .filter_map(|index| mesh.texture_coordinate(index))
                    .collect(),
                Some(bounds),
                0,
            );
            for resource_id in resource_ids {
                bounds_resource
                    .bounds_by_resource_id
                    .insert(resource_id.clone(), bounds);
                changed_bounds = true;
                geometry_resource
                    .geometry_by_resource_id
                    .insert(resource_id, geometry.clone());
                changed_geometry = true;
            }
        }

        if changed_bounds {
            runtime.set_resource(bounds_resource);
        }
        if changed_geometry {
            runtime.set_resource(geometry_resource);
        }
    }
}

/// Re-resolves authored asset references (and render-mesh indices that derive
/// from them) against the current asset registry.
fn refresh_asset_references(
    scene: &mut SceneRuntime,
    node: &EditorSceneManifestNode,
    id_map: &BTreeMap<u64, EntityID>,
) {
    let Some(entity) = id_map.get(&node.id).copied() else {
        return;
    };
    let Some(asset_reference) = scene.component::<AssetReferenceComponent>(entity) else {
        for child in &node.children {
            refresh_asset_references(scene, child, id_map);
        }
        return;
    };
    let registry = AssetRegistry::shared();
    let mut resolved = asset_reference.clone();
    if let Some(registered) = registry
        .entry(&asset_reference.asset_id)
        .or_else(|| registry.entry(&asset_reference.relative_path))
    {
        resolved.asset_id = registered.id;
        resolved.name = registered.name;
        resolved.relative_path = registered.relative_path;
        resolved.absolute_path = registered.absolute_path;
        resolved.kind = registered.kind.raw_value().to_string();
        resolved.mesh_index = registered.mesh_index;
    }
    let _ = scene.set_component(resolved.clone(), entity);
    if let Some(mut render_mesh) = scene.component::<RenderMeshComponent>(entity)
        && let Some(registered) = registry.entry(
            render_mesh
                .asset_id
                .as_deref()
                .unwrap_or(&resolved.asset_id),
        )
    {
        render_mesh.mesh_index = registered.mesh_index;
        render_mesh.asset_id = Some(registered.id);
        let _ = scene.set_component(render_mesh, entity);
    }
    for child in &node.children {
        refresh_asset_references(scene, child, id_map);
    }
}

/// `ISO8601DateFormatter().string(from: Date())`: UTC, second precision.
fn iso8601_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0);
    cove_logging::iso8601(now.floor()).replace(".000Z", "Z")
}
