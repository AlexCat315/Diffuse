//! `Editor/Sources/EditorCore/Application/Assets/Assets.swift`.
//!
//! Adding assets to the scene, annotating them semantically, tagging an entity
//! from a reference image, and reloading the project's asset catalog.

use std::path::Path;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_perception::core::perception_service::PerceptionService;
use diffuse_semantic::asset_semantic_pipeline::AssetSemanticPipeline;
use diffuse_semantic::semantic_contracts::{
    AmbiguityDecision, GeometrySignals, GeometrySignalsAABB, GeometrySignalsConnectedComponent,
    RawStructure, RawStructureBone, RawStructureMaterialSlot, RawStructureMeshRecord,
    RawStructureNode, RawStructureSkeleton, RawStructureSubmeshRecord,
};
use diffuse_semantic::semantic_world_event_mapper::SemanticWorldEventMapper;

use crate::application::editor_application::EditorApplication;
use crate::assets::asset_catalog::{EditorAsset, EditorAssetCatalog};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity as ConsoleSeverity, PlaybackState};

impl EditorApplication {
    /// Spawns the asset into the scene and selects the new entity.
    pub fn spawn_asset(&self, asset: &EditorAsset, position: Float3) -> Option<u64> {
        if !asset.kind.is_mesh() {
            self.log_console(
                &format!("Cannot spawn {}", asset.name),
                ConsoleSeverity::Warning,
                Some(asset.kind.scene_kind_label().to_string()),
                None,
                None,
            );
            return None;
        }
        let Some(id) = self.scene.spawn_entity_from_asset(asset, position) else {
            self.log_console(
                &format!("Failed to spawn {}", asset.name),
                ConsoleSeverity::Error,
                None,
                None,
                None,
            );
            return None;
        };
        self.store.dispatch(EditorAction::SetSelectedEntity(Some(id)));
        self.log_console(
            &format!("Spawned {}", asset.name),
            ConsoleSeverity::Info,
            Some(format!("entity {id}")),
            None,
            None,
        );
        self.run_semantic_annotation(id, asset);
        Some(id)
    }

    /// Adds mesh assets as one grouped operation and selects every created
    /// entity. Invalid batches are rejected before any mutation.
    pub fn spawn_assets(&self, assets: &[EditorAsset], position: Float3) -> Option<Vec<u64>> {
        if self.store.playback_state() != PlaybackState::Stopped {
            self.log_console(
                "Stop simulation before adding assets to the scene",
                ConsoleSeverity::Warning,
                None,
                None,
                None,
            );
            return None;
        }
        if assets.is_empty() || !assets.iter().all(|asset| asset.kind.is_mesh()) {
            self.log_console(
                "Select only mesh assets to add them to the scene",
                ConsoleSeverity::Warning,
                None,
                None,
                None,
            );
            return None;
        }
        let Some(entity_ids) = self.scene.spawn_entities_from_assets(assets, position) else {
            self.log_console(
                "Failed to add selected assets to the scene",
                ConsoleSeverity::Error,
                None,
                None,
                None,
            );
            return None;
        };
        self.store.dispatch(EditorAction::SetSelectedEntities(
            entity_ids.iter().copied().collect(),
        ));
        for (entity_id, asset) in entity_ids.iter().zip(assets.iter()) {
            self.log_console(
                &format!("Spawned {}", asset.name),
                ConsoleSeverity::Info,
                Some(format!("entity {entity_id}")),
                None,
                None,
            );
            self.run_semantic_annotation(*entity_id, asset);
        }
        Some(entity_ids)
    }

    /// Runs the semantic pipeline on the spawned mesh and, when it commits
    /// without ambiguity, publishes the world events it derives.
    fn run_semantic_annotation(&self, entity_id: u64, asset: &EditorAsset) {
        let Some(mesh) = AssetRegistry::shared().mesh_asset(asset.mesh_index) else {
            return;
        };
        let entity_ref = format!("scene:{entity_id}");
        let asset_uri = asset.relative_path.clone();
        let preview_image_path = Self::sibling_preview_image_path(&asset.absolute_path);
        let raw = Self::build_raw_structure(&mesh, &asset_uri, preview_image_path.as_deref());
        let signals = Self::build_geometry_signals(&mesh, &asset_uri);
        let pipeline = AssetSemanticPipeline::standard(None);
        let decision = pipeline.run(&raw, &signals);
        let proposals = match decision {
            AmbiguityDecision::AutoCommit(committed) => committed,
            AmbiguityDecision::NeedsConfirmation(_) => return,
        };
        if proposals.is_empty() {
            return;
        }
        let events = SemanticWorldEventMapper.make_world_events(&proposals, &entity_ref);
        if events.is_empty() {
            return;
        }
        if self.is_shutting_down.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        self.observe_world_events(&events);
        self.log_console(
            &format!("Semantic annotations applied to {entity_ref}"),
            ConsoleSeverity::Info,
            Some(format!("{} proposals", proposals.len())),
            None,
            None,
        );
    }

    fn sibling_preview_image_path(absolute_path: &str) -> Option<String> {
        let base = Path::new(absolute_path)
            .with_extension("")
            .to_string_lossy()
            .into_owned();
        for extension in ["png", "jpg", "jpeg", "PNG", "JPG", "JPEG"] {
            let candidate = format!("{base}.{extension}");
            if Path::new(&candidate).exists() {
                return Some(candidate);
            }
        }
        None
    }

    fn build_raw_structure(
        mesh: &diffuse_assets::asset_pipeline::MeshAsset,
        asset_uri: &str,
        preview_image_path: Option<&str>,
    ) -> RawStructure {
        let mut nodes: Vec<RawStructureNode> = Vec::new();
        for (index, node) in mesh.nodes.iter().enumerate() {
            let translation = node.local_translation;
            let scale = node.local_scale;
            let mut record = RawStructureNode::new(
                format!("node_{index}"),
                node.name.clone().unwrap_or_else(|| format!("node_{index}")),
            );
            record.parent_id = node.parent_index.map(|parent| format!("node_{parent}"));
            // Column-major 4×4 from TRS, matching Swift's port.
            record.local_transform = vec![
                scale.x, 0.0, 0.0, 0.0,
                0.0, scale.y, 0.0, 0.0,
                0.0, 0.0, scale.z, 0.0,
                translation.x, translation.y, translation.z, 1.0,
            ];
            nodes.push(record);
        }
        let node_id = nodes
            .first()
            .map(|node| node.id.clone())
            .unwrap_or_else(|| "node_0".to_string());
        let mesh_record = RawStructureMeshRecord::new(
            "mesh_0",
            node_id,
            mesh.vertex_count() as i64,
            mesh.triangle_count() as i64,
        );
        let submesh_records: Vec<RawStructureSubmeshRecord> = mesh
            .submeshes
            .iter()
            .enumerate()
            .map(|(index, submesh)| {
                RawStructureSubmeshRecord::new(
                    format!("sub_{index}"),
                    "mesh_0",
                    submesh.material_index,
                    submesh.index_start as i64,
                    submesh.index_count as i64,
                )
            })
            .collect();
        let material_slots: Vec<RawStructureMaterialSlot> = mesh
            .materials
            .iter()
            .enumerate()
            .map(|(index, material)| {
                RawStructureMaterialSlot::new(
                    format!("mat_{index}"),
                    material
                        .name
                        .clone()
                        .unwrap_or_else(|| format!("material_{index}")),
                    index as i64,
                )
            })
            .collect();
        let mut bones: Vec<RawStructureBone> = Vec::new();
        for skin in &mesh.skins {
            for joint_index in &skin.joint_node_indices {
                let Ok(joint) = usize::try_from(*joint_index) else {
                    continue;
                };
                let Some(node) = mesh.nodes.get(joint) else {
                    continue;
                };
                let bone_id = format!("bone_{joint_index}");
                let parent_bone_id = node.parent_index.and_then(|parent| {
                    skin.joint_node_indices
                        .contains(&parent)
                        .then(|| format!("bone_{parent}"))
                });
                let mut bone = RawStructureBone::new(
                    &bone_id,
                    node.name.clone().unwrap_or_else(|| bone_id.clone()),
                );
                bone.parent_id = parent_bone_id;
                bones.push(bone);
            }
        }
        let skeleton = if bones.is_empty() {
            None
        } else {
            Some(RawStructureSkeleton::new(bones))
        };
        let mut structure = RawStructure::new(asset_uri);
        structure.preview_image_path = preview_image_path.map(str::to_string);
        structure.nodes = nodes;
        structure.meshes = vec![mesh_record];
        structure.submeshes = submesh_records;
        structure.material_slots = material_slots;
        structure.skeleton = skeleton;
        structure
    }

    fn build_geometry_signals(
        mesh: &diffuse_assets::asset_pipeline::MeshAsset,
        asset_uri: &str,
    ) -> GeometrySignals {
        let (min, max) = mesh.local_bounds();
        let aabb = GeometrySignalsAABB::new(
            (min.x, min.y, min.z),
            (max.x, max.y, max.z),
        );
        let component = GeometrySignalsConnectedComponent::new(
            "cc_0",
            "mesh_0",
            mesh.triangle_count() as i64,
            aabb.clone(),
        );
        let dx = max.x - min.x;
        let dy = max.y - min.y;
        let dz = max.z - min.z;
        let mut signals = GeometrySignals::new(asset_uri);
        signals.connected_components = vec![component];
        signals.surface_area = 2.0 * (dx * dy + dy * dz + dx * dz);
        signals.volume_estimate = dx * dy * dz;
        signals
    }

    /// Runs visual perception on `image_url` and injects the inferred
    /// properties into the world and the session for `entity_ref`.
    pub fn tag_entity(&self, entity_ref: &str, image_url: &Path) {
        match PerceptionService::tag_default(&self.perception_service, entity_ref, image_url) {
            Ok(events) => {
                if self.is_shutting_down.load(std::sync::atomic::Ordering::Acquire) {
                    return;
                }
                self.observe_world_events(&events);
                self.log_console(
                    &format!("Tagged {entity_ref}"),
                    ConsoleSeverity::Info,
                    Some(format!("{} inferred properties", events.len())),
                    None,
                    None,
                );
            }
            Err(error) => {
                if self.is_shutting_down.load(std::sync::atomic::Ordering::Acquire) {
                    return;
                }
                self.log_console(
                    &format!("Perception unavailable for {entity_ref}"),
                    ConsoleSeverity::Warning,
                    Some(error.to_string()),
                    None,
                    None,
                );
            }
        }
    }

    /// Reloads the project's importable files and refreshes scene geometry.
    pub fn reload_assets(&self) -> Option<usize> {
        match EditorAssetCatalog::load_project_default(&self.project_directory) {
            Ok(assets) => {
                self.scene.refresh_asset_geometry();
                self.render_gate
                    .replace(crate::editing::viewport::editor_viewport_render_gate::EditorViewportRenderGate::new());
                self.reload_project_scripts(true, true);
                self.store.dispatch(EditorAction::ForceUIRefresh);
                self.log_console(
                    "Reloaded assets",
                    ConsoleSeverity::Info,
                    Some(format!("{} importable files", assets.len())),
                    None,
                    None,
                );
                Some(assets.len())
            }
            Err(error) => {
                self.log_console(
                    "Failed to reload assets",
                    ConsoleSeverity::Error,
                    Some(error.to_string()),
                    None,
                    None,
                );
                None
            }
        }
    }
}
