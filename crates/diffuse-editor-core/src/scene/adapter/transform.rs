//! `Editor/Sources/EditorCore/Scene/Adapter/Transform.swift`.
//!
//! Frame ticking, render-scene accessors and the transform helpers the viewport
//! and the inspector share.

use std::collections::BTreeMap;

use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_kernel::input_event::InputEvent;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::GPUParticleSimulationEventSnapshotBridge;
use diffuse_render::core::render_stats::GPUParticleSimulationEventSnapshot;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::particle_events::ParticleEvent;
use diffuse_scene::particles::particle_gpu_simulation_plan::ParticleGPUSimulationPlan;
use diffuse_scene::particles::particle_scalability::ParticleScalabilityStateResource;
use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use diffuse_scene::particles::particle_stats::ParticleFrameStatsResource;
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderScene};
use diffuse_scene::runtime_world::LocalTransform;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;

impl EditorSceneAdapter {
    pub fn current_render_camera(&self) -> RenderCamera {
        if self.uses_editor_viewport_camera() {
            return self.editor_viewport_camera.get();
        }
        if let Some(extracted) = self.scene().extracted_render_scene()
            && extracted.active_camera_entity.is_some()
        {
            return extracted.scene.camera;
        }
        self.editor_viewport_camera.get()
    }

    /// Swift's defaulted `tickScene(deltaTime:frameIndex:inputEvents:drivesAudio:)`.
    #[allow(clippy::too_many_arguments)]
    pub fn tick_scene(
        &self,
        delta_time: f64,
        frame_index: u64,
        input_events: Vec<InputEvent>,
        drives_audio: bool,
    ) -> bool {
        self.apply_pending_particle_feedback();
        self.with_scene_mut(|scene| {
            let _ = scene.tick(delta_time, frame_index, input_events);
        });
        if drives_audio {
            let scene = self.scene();
            self.audio_engine.tick(scene.world(), Float3::ZERO);
        }
        true
    }

    /// The all-default form of [`Self::tick_scene`].
    pub fn tick_scene_default(&self) -> bool {
        self.tick_scene(0.0, 0, Vec::new(), false)
    }

    pub fn register_script(
        &self,
        script: diffuse_script::Script,
        name: Option<&str>,
    ) -> diffuse_script::ScriptHandle {
        self.script_runtime.register(script, name)
    }

    pub fn current_scene_snapshot(&self) -> diffuse_scene::scene_runtime::SceneRuntimeSnapshot {
        self.scene().snapshot()
    }

    pub fn current_in_game_canvas(&self) -> InGameCanvas {
        self.scene()
            .resource::<InGameCanvas>()
            .unwrap_or_else(InGameCanvas::new)
    }

    pub fn make_particle_simulation_feedback_handler(
        &self,
    ) -> std::sync::Arc<dyn Fn(&[GPUParticleSimulationEventSnapshot]) + Send + Sync> {
        self.particle_feedback.make_handler()
    }

    fn apply_pending_particle_feedback(&self) {
        let snapshots = self.particle_feedback.drain();
        if snapshots.is_empty() {
            return;
        }

        let total_readback_event_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.total_event_count as i64)
            .sum();
        let dropped_readback_event_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.dropped_event_count as i64)
            .sum();
        let gpu_alive_particle_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.alive_particle_count as i64)
            .sum();
        let gpu_expired_particle_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.expired_particle_count as i64)
            .sum();
        let gpu_collision_event_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.collision_event_count as i64)
            .sum();
        let gpu_spawned_particle_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.gpu_spawned_particle_count as i64)
            .sum();
        let gpu_dropped_spawn_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.gpu_dropped_spawn_count as i64)
            .sum();
        let gpu_compacted_particle_count: i64 = snapshots
            .iter()
            .map(|snapshot| snapshot.compacted_particle_count as i64)
            .sum();
        let mut events_by_entity: BTreeMap<EntityID, Vec<ParticleEvent>> = BTreeMap::new();
        for snapshot in &snapshots {
            let Some(raw_value) = snapshot.emitter_raw_value else {
                continue;
            };
            let events = snapshot.make_particle_events();
            if events.is_empty() {
                continue;
            }
            events_by_entity
                .entry(EntityID::from_raw_value(raw_value))
                .or_default()
                .extend(events);
        }

        let mut report = if events_by_entity.is_empty() {
            ParticleSimulationEventApplyReport::empty()
        } else {
            self.with_scene_mut(|scene| scene.apply_particle_simulation_events(&events_by_entity))
        };
        report.total_readback_event_count = total_readback_event_count;
        report.dropped_readback_event_count = dropped_readback_event_count;
        report.gpu_alive_particle_count = gpu_alive_particle_count;
        report.gpu_expired_particle_count = gpu_expired_particle_count;
        report.gpu_collision_event_count = gpu_collision_event_count;
        report.gpu_spawned_particle_count = gpu_spawned_particle_count;
        report.gpu_dropped_spawn_count = gpu_dropped_spawn_count;
        report.gpu_compacted_particle_count = gpu_compacted_particle_count;
        self.with_scene_mut(|scene| scene.apply_particle_simulation_readback_stats(&report));
        self.particle_feedback.record(report);
    }

    pub fn current_joint_palette_map(&self) -> JointPaletteMap {
        self.scene()
            .resource::<JointPaletteMap>()
            .unwrap_or_default()
    }

    pub fn current_render_scene(&self) -> RenderScene {
        let mut render_scene = self.scene().render_scene();
        render_scene.camera = self.current_render_camera();
        render_scene
    }

    pub fn current_particle_frame_stats(&self) -> ParticleFrameStatsResource {
        self.scene().particle_frame_stats()
    }

    pub fn current_particle_simulation_event_apply_report(
        &self,
    ) -> ParticleSimulationEventApplyReport {
        self.particle_feedback.report()
    }

    pub fn current_particle_scalability_state(&self) -> ParticleScalabilityStateResource {
        self.scene().particle_scalability_state()
    }

    pub fn current_particle_gpu_simulation_plan(
        &self,
        raw_id: Option<u64>,
    ) -> Option<ParticleGPUSimulationPlan> {
        let raw_id = raw_id?;
        let entity = self.make_entity_id(raw_id)?;
        self.scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.gpu_simulation_plan())
    }

    pub fn current_particle_module_validation_issues(
        &self,
        raw_id: Option<u64>,
    ) -> Vec<diffuse_scene::particles::particle_modules::ParticleModuleIssue> {
        let Some(raw_id) = raw_id else {
            return Vec::new();
        };
        let Some(entity) = self.make_entity_id(raw_id) else {
            return Vec::new();
        };
        let Some(emitter) = self.scene().component::<ParticleEmitter>(entity) else {
            return Vec::new();
        };
        emitter.module_validation_issues()
    }

    pub fn entity_world_position(&self, raw_id: u64) -> Option<Float3> {
        let entity = self.make_entity_id(raw_id)?;
        self.scene()
            .world_transform(entity)
            .map(|transform| transform.translation())
    }

    pub fn entity_world_matrix(&self, raw_id: u64) -> Option<Float4x4> {
        let entity = self.make_entity_id(raw_id)?;
        self.scene()
            .world_transform(entity)
            .map(|transform| transform.matrix)
    }

    pub fn entity_local_translation(&self, raw_id: u64) -> Option<Float3> {
        let entity = self.make_entity_id(raw_id)?;
        self.scene()
            .local_transform(entity)
            .map(|local| local.translation())
    }

    pub fn set_entity_local_translation(&self, raw_id: u64, value: Float3) {
        let Some(entity) = self.make_entity_id(raw_id) else {
            return;
        };
        let Some(mut local) = self.scene().local_transform(entity) else {
            return;
        };
        local
            .matrix
            .set_column(3, Float4::new(value.x, value.y, value.z, 1.0));
        let _ = self.apply_scene_transaction(
            "scene.set_local_transform",
            "Update entity translation",
            vec![raw_id],
            vec![
                diffuse_intent::transactions::transaction_ir::SceneMutation::SetLocalTransform {
                    entity_id: raw_id,
                    transform: local,
                },
            ],
        );
    }

    pub fn entity_local_matrix(&self, raw_id: u64) -> Option<Float4x4> {
        let entity = self.make_entity_id(raw_id)?;
        self.scene()
            .local_transform(entity)
            .map(|local| local.matrix)
    }

    pub fn entity_parent_world_matrix(&self, raw_id: u64) -> Float4x4 {
        let Some(entity) = self.make_entity_id(raw_id) else {
            return MATRIX_IDENTITY_FLOAT4X4;
        };
        let scene = self.scene();
        let Some(parent) = scene.parent(entity) else {
            return MATRIX_IDENTITY_FLOAT4X4;
        };
        scene
            .world_transform(parent)
            .map(|transform| transform.matrix)
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4)
    }

    pub fn entity_has_ancestor(
        &self,
        raw_id: u64,
        candidate_raw_ids: &std::collections::BTreeSet<u64>,
    ) -> bool {
        let scene = self.scene();
        let Some(mut current) = self
            .make_entity_id(raw_id)
            .and_then(|entity| scene.parent(entity))
        else {
            return false;
        };
        loop {
            if candidate_raw_ids.contains(&current.raw_value()) {
                return true;
            }
            let Some(parent) = scene.parent(current) else {
                return false;
            };
            current = parent;
        }
    }

    pub fn set_entity_local_matrix(&self, raw_id: u64, matrix: Float4x4) {
        let _ = self.set_entity_local_matrices(&BTreeMap::from([(raw_id, matrix)]));
    }

    /// Applies a multi-selection transform atomically. This prevents a locked
    /// or stale member from leaving only part of the selection transformed.
    pub fn set_entity_local_matrices(
        &self,
        matrices_by_entity_id: &BTreeMap<u64, Float4x4>,
    ) -> bool {
        let entity_ids: Vec<u64> = matrices_by_entity_id.keys().copied().collect();
        if entity_ids.is_empty() {
            return false;
        }
        let scene = self.scene();
        let mut mutations: Vec<diffuse_intent::transactions::transaction_ir::SceneMutation> =
            Vec::with_capacity(entity_ids.len());
        for raw_id in &entity_ids {
            let Some(matrix) = matrices_by_entity_id.get(raw_id) else {
                return false;
            };
            let Some(entity) = self.make_entity_id(*raw_id) else {
                return false;
            };
            if !scene.contains(entity) {
                return false;
            }
            let mut local = scene
                .local_transform(entity)
                .unwrap_or(LocalTransform::IDENTITY);
            local.matrix = *matrix;
            mutations.push(
                diffuse_intent::transactions::transaction_ir::SceneMutation::SetLocalTransform {
                    entity_id: *raw_id,
                    transform: local,
                },
            );
        }
        self.apply_scene_transaction(
            if entity_ids.len() == 1 {
                "scene.set_local_transform"
            } else {
                "scene.set_local_transforms"
            },
            if entity_ids.len() == 1 {
                "Update entity transform"
            } else {
                "Update entity transforms"
            },
            entity_ids.clone(),
            mutations,
        )
        .is_some()
    }

    fn make_entity_id(&self, raw_id: u64) -> Option<EntityID> {
        Some(EntityID::new(raw_id as u32, (raw_id >> 32) as u32))
    }
}
