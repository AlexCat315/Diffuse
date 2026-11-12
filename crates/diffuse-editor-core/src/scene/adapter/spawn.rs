//! `Editor/Sources/EditorCore/Scene/Adapter/Spawn.swift`.
//!
//! Ready-to-use entities exposed by the editor's Hierarchy create menu. These
//! templates map to SceneRuntime primitives so they work in a new project
//! before any assets have been imported.

use std::collections::BTreeMap;

use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_math::simd::simd_compat::{Float2, Float3};
use diffuse_render::registries::mesh_bounds_registry::MeshBoundsRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_scene::physics::collider::{Collider, ColliderShape, SpatialAABB};
use diffuse_scene::physics::queries::spatial_queries::{
    MeshColliderBoundsResource, MeshColliderGeometry, MeshColliderGeometryResource,
};
use diffuse_scene::rendering::render_extraction::{LightType, RenderMeshComponent};
use diffuse_scene::scene_bootstrap::{AssetReferenceComponent, SceneNameComponent};

use crate::assets::asset_catalog::EditorAsset;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;

/// Ready-to-use entities exposed by the editor's Hierarchy create menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorEntityTemplate {
    Empty,
    Cube,
    DirectionalLight,
    PointLight,
    SpotLight,
    Camera,
}

impl EditorEntityTemplate {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorEntityTemplate; 6] = [
        EditorEntityTemplate::Empty,
        EditorEntityTemplate::Cube,
        EditorEntityTemplate::DirectionalLight,
        EditorEntityTemplate::PointLight,
        EditorEntityTemplate::SpotLight,
        EditorEntityTemplate::Camera,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            EditorEntityTemplate::Empty => "empty",
            EditorEntityTemplate::Cube => "cube",
            EditorEntityTemplate::DirectionalLight => "directionalLight",
            EditorEntityTemplate::PointLight => "pointLight",
            EditorEntityTemplate::SpotLight => "spotLight",
            EditorEntityTemplate::Camera => "camera",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            EditorEntityTemplate::Empty => "Empty Entity",
            EditorEntityTemplate::Cube => "Cube",
            EditorEntityTemplate::DirectionalLight => "Directional Light",
            EditorEntityTemplate::PointLight => "Point Light",
            EditorEntityTemplate::SpotLight => "Spot Light",
            EditorEntityTemplate::Camera => "Camera",
        }
    }
}

impl EditorSceneAdapter {
    /// Creates a built-in entity without requiring a project asset. The
    /// operation participates in editor history and returns the new raw id so
    /// the caller can select it immediately.
    pub fn spawn_entity(
        &self,
        template: EditorEntityTemplate,
        position: Option<Float3>,
        parent_id: Option<u64>,
    ) -> Option<u64> {
        let spawn_position = position.unwrap_or_else(|| self.default_spawn_position(template));
        let mutation = match template {
            EditorEntityTemplate::Empty => SceneMutation::SpawnEmptyEntity {
                label: self.unique_display_name("Empty Entity"),
                position: spawn_position,
                parent_id,
            },
            EditorEntityTemplate::Cube => SceneMutation::SpawnImportedMeshEntity {
                label: self.unique_display_name("Cube"),
                kind_label: "Mesh".to_string(),
                mesh_index: 0,
                position: spawn_position,
                parent_id,
            },
            EditorEntityTemplate::DirectionalLight => SceneMutation::SpawnLightEntity {
                label: self.unique_display_name("Directional Light"),
                light_type: LightType::Directional,
                position: spawn_position,
                initial_intensity: None,
                initial_color: None,
                initial_range: None,
                initial_cast_shadows: None,
                parent_id,
            },
            EditorEntityTemplate::PointLight => SceneMutation::SpawnLightEntity {
                label: self.unique_display_name("Point Light"),
                light_type: LightType::Point,
                position: spawn_position,
                initial_intensity: None,
                initial_color: None,
                initial_range: None,
                initial_cast_shadows: None,
                parent_id,
            },
            EditorEntityTemplate::SpotLight => SceneMutation::SpawnLightEntity {
                label: self.unique_display_name("Spot Light"),
                light_type: LightType::Spot,
                position: spawn_position,
                initial_intensity: None,
                initial_color: None,
                initial_range: None,
                initial_cast_shadows: None,
                parent_id,
            },
            EditorEntityTemplate::Camera => SceneMutation::SpawnCameraEntity {
                label: self.unique_display_name("Camera"),
                position: spawn_position,
                initial_fov_y_degrees: None,
                parent_id,
            },
        };

        let summary = format!("Create {}", template.display_name().to_lowercase());
        self.apply_scene_transaction(
            "scene.create_entity",
            summary,
            parent_id.map(|parent| vec![parent]).unwrap_or_default(),
            vec![mutation],
        )
        .and_then(|result| result.created_entity_ids.first().copied())
    }

    /// Swift's `spawnEntity(template:)` defaults: no position, no parent.
    pub fn spawn_entity_default(&self, template: EditorEntityTemplate) -> Option<u64> {
        self.spawn_entity(template, None, None)
    }

    fn default_spawn_position(&self, template: EditorEntityTemplate) -> Float3 {
        match template {
            EditorEntityTemplate::Empty | EditorEntityTemplate::Cube => Float3::ZERO,
            EditorEntityTemplate::DirectionalLight => Float3::new(0.0, 3.0, 0.0),
            EditorEntityTemplate::PointLight | EditorEntityTemplate::SpotLight => {
                Float3::new(0.0, 2.0, 0.0)
            }
            EditorEntityTemplate::Camera => Float3::new(0.0, 1.5, 5.0),
        }
    }

    /// 在场景里生成一个新实体并立即可见，返回 raw entity id。
    /// 调用方一般紧接着把返回的 id 写回 store 作为新的选中态。
    pub fn spawn_entity_from_asset(&self, asset: &EditorAsset, position: Float3) -> Option<u64> {
        self.with_edit_history_group(|| {
            let label = self.unique_display_name(&asset.name);
            let result = self.apply_scene_transaction(
                "scene.spawn_entity",
                "Spawn imported mesh entity",
                Vec::new(),
                vec![SceneMutation::SpawnImportedMeshEntity {
                    label,
                    kind_label: asset.kind.scene_kind_label().to_string(),
                    mesh_index: asset.mesh_index,
                    position,
                    parent_id: None,
                }],
            );
            let entity_id = result?.created_entity_ids.first().copied()?;
            self.attach_asset_reference(entity_id, asset);
            self.attach_mesh_collider_if_available(entity_id, asset.mesh_index);
            self.attach_animation_player_if_available(entity_id, asset.mesh_index);
            Some(entity_id)
        })
    }

    /// Swift's `at position: SIMD3<Float> = .zero` default.
    pub fn spawn_entity_from_asset_default(&self, asset: &EditorAsset) -> Option<u64> {
        self.spawn_entity_from_asset(asset, Float3::ZERO)
    }

    /// Adds a group of mesh assets in a compact grid and records the whole
    /// operation as one undo step. If any member fails, the partial group is
    /// rolled back before returning.
    pub fn spawn_entities_from_assets(
        &self,
        assets: &[EditorAsset],
        position: Float3,
    ) -> Option<Vec<u64>> {
        if assets.is_empty() || !assets.iter().all(|asset| asset.kind.is_mesh()) {
            return None;
        }

        let start_revision = self.revision();
        let column_count = ((assets.len() as f64).sqrt().ceil() as usize).max(1);
        let row_count = assets.len().div_ceil(column_count);
        let spacing: f32 = 1.5;
        let spawned_ids = self.with_edit_history_group(|| {
            let mut result: Vec<u64> = Vec::with_capacity(assets.len());
            for (index, asset) in assets.iter().enumerate() {
                let row = index / column_count;
                let column = index % column_count;
                let columns_in_row = column_count.min(assets.len() - row * column_count);
                let offset = Float3::new(
                    (column as f32 - (columns_in_row as f32 - 1.0) * 0.5) * spacing,
                    0.0,
                    (row as f32 - (row_count as f32 - 1.0) * 0.5) * spacing,
                );
                let Some(entity_id) = self.spawn_entity_from_asset(asset, position + offset) else {
                    break;
                };
                result.push(entity_id);
            }
            result
        });

        if spawned_ids.len() != assets.len() {
            if self.revision() != start_revision {
                let _ = self.undo_edit();
            }
            return None;
        }
        Some(spawned_ids)
    }

    /// Swift's `at position: SIMD3<Float> = .zero` default.
    pub fn spawn_entities_from_assets_default(&self, assets: &[EditorAsset]) -> Option<Vec<u64>> {
        self.spawn_entities_from_assets(assets, Float3::ZERO)
    }

    fn unique_display_name(&self, base: &str) -> String {
        let scene = self.scene();
        let existing: std::collections::BTreeSet<String> = scene
            .entities()
            .into_iter()
            .filter_map(|entity| {
                scene
                    .component::<SceneNameComponent>(entity)
                    .map(|name| name.value)
            })
            .collect();
        if !existing.contains(base) {
            return base.to_string();
        }
        let mut suffix = 2;
        while existing.contains(&format!("{base} {suffix}")) {
            suffix += 1;
        }
        format!("{base} {suffix}")
    }

    fn attach_asset_reference(&self, entity_id: u64, asset: &EditorAsset) {
        let Some(entity) = make_entity_id(entity_id) else {
            return;
        };
        let mut updated_mesh = false;
        self.with_scene_mut(|scene| {
            if !scene.contains(entity) {
                return;
            }
            let _ = scene.set_component(
                AssetReferenceComponent::new(
                    asset.id.clone(),
                    asset.name.clone(),
                    asset.relative_path.clone(),
                    asset.absolute_path.clone(),
                    asset.kind.raw_value(),
                    asset.mesh_index,
                ),
                entity,
            );
            if let Some(mut render_mesh) = scene.component::<RenderMeshComponent>(entity) {
                render_mesh.asset_id = Some(asset.id.clone());
                let _ = scene.set_component(render_mesh, entity);
                updated_mesh = true;
            }
        });
        if updated_mesh {
            self.notify_revision_changed(true, None);
        }
    }

    fn attach_mesh_collider_if_available(&self, entity_id: u64, mesh_index: i64) {
        let Some(entity) = make_entity_id(entity_id) else {
            return;
        };
        let resource_id = mesh_collider_resource_id(mesh_index);
        let geometry = self.mesh_collider_geometry(mesh_index);
        let bounds = MeshBoundsRegistry::bounds(mesh_index)
            .map(|(min, max)| SpatialAABB::new(min, max))
            .or_else(|| geometry.as_ref().map(|geometry| geometry.local_bounds));
        if bounds.is_none() && geometry.is_none() {
            return;
        }

        self.with_scene_mut(|scene| {
            if !scene.contains(entity) {
                return;
            }
            if let Some(bounds) = bounds {
                let mut resource = scene
                    .resource::<MeshColliderBoundsResource>()
                    .unwrap_or_else(|| MeshColliderBoundsResource::new(BTreeMap::new(), None));
                resource
                    .bounds_by_resource_id
                    .insert(resource_id.clone(), bounds);
                scene.set_resource(resource);
            }
            if let Some(geometry) = geometry {
                let mut resource = scene
                    .resource::<MeshColliderGeometryResource>()
                    .unwrap_or_else(|| MeshColliderGeometryResource::new(BTreeMap::new(), None));
                resource
                    .geometry_by_resource_id
                    .insert(resource_id.clone(), geometry);
                scene.set_resource(resource);
            }
            let _ = scene.set_component(
                Collider::with_shape(ColliderShape::Mesh {
                    resource_id: Some(resource_id),
                    center: Float3::ZERO,
                }),
                entity,
            );
        });
        self.notify_revision_changed(true, None);
    }

    fn attach_animation_player_if_available(&self, entity_id: u64, mesh_index: i64) {
        let Some(entity) = make_entity_id(entity_id) else {
            return;
        };
        let Some(mesh) = AssetRegistry::shared().mesh_asset(mesh_index) else {
            return;
        };
        if mesh.animations.is_empty() {
            return;
        }
        self.with_scene_mut(|scene| {
            if scene.contains(entity) {
                let _ = scene.set_component(AnimationPlayer::default(), entity);
            }
        });
        self.notify_revision_changed(true, None);
    }

    fn mesh_collider_geometry(&self, mesh_index: i64) -> Option<MeshColliderGeometry> {
        let mesh: MeshAsset = AssetRegistry::shared().mesh_asset(mesh_index)?;
        if mesh.triangle_count() == 0 {
            return None;
        }
        let positions: Vec<Float3> = (0..mesh.vertex_count())
            .filter_map(|index| mesh.position(index as i64))
            .collect();
        let texture_coordinates: Vec<Float2> = (0..mesh.vertex_count())
            .filter_map(|index| mesh.texture_coordinate(index as i64))
            .collect();
        let (min, max) = mesh.local_bounds();
        Some(MeshColliderGeometry::new(
            positions,
            mesh.indices.clone(),
            Vec::new(),
            texture_coordinates,
            Some(SpatialAABB::new(min, max)),
            0,
        ))
    }
}

fn make_entity_id(raw_id: u64) -> Option<EntityID> {
    Some(EntityID::new(
        (raw_id & 0xFFFF_FFFF) as u32,
        (raw_id >> 32) as u32,
    ))
}

fn mesh_collider_resource_id(mesh_index: i64) -> String {
    format!("meshIndex:{mesh_index}")
}
