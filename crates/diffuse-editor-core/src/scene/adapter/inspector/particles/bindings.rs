//! Translation of Editor/Sources/EditorCore/Scene/Adapter/Inspector/Particles/Bindings.swift.
//!
//! Inspector bindings for the particle emitter form. Every setter writes the
//! whole `ParticleEmitter` through one scene transaction, matching Swift's
//! `updateParticleEmitter`.

use std::collections::BTreeSet;
use std::path::Path;

use cove_ui_compose::scene_core::{Binding, Color};
use diffuse_assets::asset_registry::ImportableAssetKind;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_math::simd::simd_compat::{Float3, Float4};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::particle_curve::ParticleCurve;
use diffuse_scene::particles::particle_events::ParticleSubEmitter;
use diffuse_scene::particles::particle_gpu_simulation_plan::{
    ParticleGPUSimulationPlanStatus, ParticleGPUSimulationUnsupportedReason,
};
use diffuse_scene::particles::particle_modules::ParticleModuleStack;
use diffuse_scene::particles::particle_types::{
    ParticleBlendMode, ParticleCollisionMode, ParticleEmissionShape, ParticleForceMode,
    ParticleRenderAlignment, ParticleRenderBoundsMode, ParticleRenderMode,
    ParticleSimulationBackend, ParticleSimulationSpace, ParticleSortMode,
    ParticleSubEmitterTrigger, ParticleTextureSheetPlaybackMode, ParticleVectorFieldMode,
};

use crate::assets::asset_catalog::EditorAssetCatalog;
use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::EditorInspectorAssetRef;

/// `WritableKeyPath<ParticleEmitter, Bool>` cases used by the emitter form.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ParticleBoolField {
    Emitting,
    Looping,
}

impl ParticleBoolField {
    fn get(self, emitter: &ParticleEmitter) -> bool {
        match self {
            ParticleBoolField::Emitting => emitter.settings.emission.is_emitting,
            ParticleBoolField::Looping => emitter.settings.emission.looping,
        }
    }

    fn set(self, emitter: &mut ParticleEmitter, value: bool) {
        match self {
            ParticleBoolField::Emitting => emitter.settings.emission.is_emitting = value,
            ParticleBoolField::Looping => emitter.settings.emission.looping = value,
        }
    }
}

/// `WritableKeyPath<ParticleEmitter, Float>` cases used by the emitter form.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ParticleFloatField {
    Duration,
    SimulationSpeed,
    PrewarmTime,
    PrewarmStep,
    EmissionRate,
    DistanceEmissionRate,
    BurstInterval,
    Lifetime,
    SubEmitterProbability,
    SubEmitterInheritVelocity,
    SubEmitterLifetime,
    SubEmitterStartSize,
    SubEmitterEndSize,
    SpawnRadius,
    ConeRadius,
    ConeHeight,
    StartSize,
    EndSize,
    SizeRandomness,
    StartRotation,
    RotationRandomness,
    AngularVelocity,
    AngularVelocityRandomness,
    VelocityInheritance,
    NoiseStrength,
    NoiseScale,
    NoiseSpeed,
    ForceRadius,
    ForceStrength,
    ForceFalloff,
    VectorFieldStrength,
    VectorFieldScale,
    VectorFieldScrollSpeed,
    CollisionPlaneY,
    CollisionRestitution,
    CollisionDamping,
    RibbonWidthScale,
    RibbonTailWidthScale,
    RibbonTailAlphaScale,
    RibbonMaxSegmentLength,
    RibbonJoinOverlapScale,
    RibbonTextureTiling,
    RibbonTextureOffset,
    VelocityStretchScale,
    VelocityStretchMax,
    MaxRenderDistance,
    RenderDistanceFadeRange,
    RenderLodStartDistance,
    RenderLodEndDistance,
    RenderLodMinParticleScale,
    RenderBoundsRadius,
    FrameRate,
    TrailLength,
    TrailEndSizeScale,
    TrailEndAlphaScale,
}

impl ParticleFloatField {
    fn get(self, emitter: &ParticleEmitter) -> f32 {
        let settings = &emitter.settings;
        match self {
            ParticleFloatField::Duration => settings.emission.duration,
            ParticleFloatField::SimulationSpeed => settings.emission.simulation_speed,
            ParticleFloatField::PrewarmTime => settings.emission.prewarm_time,
            ParticleFloatField::PrewarmStep => settings.emission.prewarm_step,
            ParticleFloatField::EmissionRate => settings.emission.emission_rate,
            ParticleFloatField::DistanceEmissionRate => settings.emission.distance_emission_rate,
            ParticleFloatField::BurstInterval => settings.emission.burst_interval,
            ParticleFloatField::Lifetime => settings.appearance.lifetime,
            ParticleFloatField::SubEmitterProbability => settings.sub_emitters.legacy_probability,
            ParticleFloatField::SubEmitterInheritVelocity => {
                settings.sub_emitters.legacy_inherit_velocity
            }
            ParticleFloatField::SubEmitterLifetime => settings.sub_emitters.legacy_lifetime,
            ParticleFloatField::SubEmitterStartSize => settings.sub_emitters.legacy_start_size,
            ParticleFloatField::SubEmitterEndSize => settings.sub_emitters.legacy_end_size,
            ParticleFloatField::SpawnRadius => settings.shape.spawn_radius,
            ParticleFloatField::ConeRadius => settings.shape.cone_radius,
            ParticleFloatField::ConeHeight => settings.shape.cone_height,
            ParticleFloatField::StartSize => settings.appearance.start_size,
            ParticleFloatField::EndSize => settings.appearance.end_size,
            ParticleFloatField::SizeRandomness => settings.appearance.size_randomness,
            ParticleFloatField::StartRotation => settings.appearance.start_rotation,
            ParticleFloatField::RotationRandomness => settings.appearance.rotation_randomness,
            ParticleFloatField::AngularVelocity => settings.appearance.angular_velocity,
            ParticleFloatField::AngularVelocityRandomness => {
                settings.appearance.angular_velocity_randomness
            }
            ParticleFloatField::VelocityInheritance => settings.velocity.velocity_inheritance,
            ParticleFloatField::NoiseStrength => settings.forces.noise_strength,
            ParticleFloatField::NoiseScale => settings.forces.noise_scale,
            ParticleFloatField::NoiseSpeed => settings.forces.noise_speed,
            ParticleFloatField::ForceRadius => settings.forces.force_radius,
            ParticleFloatField::ForceStrength => settings.forces.force_strength,
            ParticleFloatField::ForceFalloff => settings.forces.force_falloff,
            ParticleFloatField::VectorFieldStrength => settings.forces.vector_field_strength,
            ParticleFloatField::VectorFieldScale => settings.forces.vector_field_scale,
            ParticleFloatField::VectorFieldScrollSpeed => settings.forces.vector_field_scroll_speed,
            ParticleFloatField::CollisionPlaneY => settings.collision.collision_plane_y,
            ParticleFloatField::CollisionRestitution => settings.collision.collision_restitution,
            ParticleFloatField::CollisionDamping => settings.collision.collision_damping,
            ParticleFloatField::RibbonWidthScale => settings.trails.ribbon_width_scale,
            ParticleFloatField::RibbonTailWidthScale => settings.trails.ribbon_tail_width_scale,
            ParticleFloatField::RibbonTailAlphaScale => settings.trails.ribbon_tail_alpha_scale,
            ParticleFloatField::RibbonMaxSegmentLength => settings.trails.ribbon_max_segment_length,
            ParticleFloatField::RibbonJoinOverlapScale => settings.trails.ribbon_join_overlap_scale,
            ParticleFloatField::RibbonTextureTiling => settings.trails.ribbon_texture_tiling,
            ParticleFloatField::RibbonTextureOffset => settings.trails.ribbon_texture_offset,
            ParticleFloatField::VelocityStretchScale => settings.renderer.velocity_stretch_scale,
            ParticleFloatField::VelocityStretchMax => settings.renderer.velocity_stretch_max,
            ParticleFloatField::MaxRenderDistance => settings.renderer.max_render_distance,
            ParticleFloatField::RenderDistanceFadeRange => {
                settings.renderer.render_distance_fade_range
            }
            ParticleFloatField::RenderLodStartDistance => {
                settings.renderer.render_lod_start_distance
            }
            ParticleFloatField::RenderLodEndDistance => settings.renderer.render_lod_end_distance,
            ParticleFloatField::RenderLodMinParticleScale => {
                settings.renderer.render_lod_min_particle_scale
            }
            ParticleFloatField::RenderBoundsRadius => settings.renderer.render_bounds_radius,
            ParticleFloatField::FrameRate => settings.texture_sheet.frame_rate,
            ParticleFloatField::TrailLength => settings.trails.trail_length,
            ParticleFloatField::TrailEndSizeScale => settings.trails.trail_end_size_scale,
            ParticleFloatField::TrailEndAlphaScale => settings.trails.trail_end_alpha_scale,
        }
    }

    fn set(self, emitter: &mut ParticleEmitter, value: f32) {
        let settings = &mut emitter.settings;
        match self {
            ParticleFloatField::Duration => settings.emission.duration = value,
            ParticleFloatField::SimulationSpeed => settings.emission.simulation_speed = value,
            ParticleFloatField::PrewarmTime => settings.emission.prewarm_time = value,
            ParticleFloatField::PrewarmStep => settings.emission.prewarm_step = value,
            ParticleFloatField::EmissionRate => settings.emission.emission_rate = value,
            ParticleFloatField::DistanceEmissionRate => {
                settings.emission.distance_emission_rate = value
            }
            ParticleFloatField::BurstInterval => settings.emission.burst_interval = value,
            ParticleFloatField::Lifetime => settings.appearance.lifetime = value,
            ParticleFloatField::SubEmitterProbability => {
                settings.sub_emitters.legacy_probability = value
            }
            ParticleFloatField::SubEmitterInheritVelocity => {
                settings.sub_emitters.legacy_inherit_velocity = value
            }
            ParticleFloatField::SubEmitterLifetime => settings.sub_emitters.legacy_lifetime = value,
            ParticleFloatField::SubEmitterStartSize => {
                settings.sub_emitters.legacy_start_size = value
            }
            ParticleFloatField::SubEmitterEndSize => settings.sub_emitters.legacy_end_size = value,
            ParticleFloatField::SpawnRadius => settings.shape.spawn_radius = value,
            ParticleFloatField::ConeRadius => settings.shape.cone_radius = value,
            ParticleFloatField::ConeHeight => settings.shape.cone_height = value,
            ParticleFloatField::StartSize => settings.appearance.start_size = value,
            ParticleFloatField::EndSize => settings.appearance.end_size = value,
            ParticleFloatField::SizeRandomness => settings.appearance.size_randomness = value,
            ParticleFloatField::StartRotation => settings.appearance.start_rotation = value,
            ParticleFloatField::RotationRandomness => {
                settings.appearance.rotation_randomness = value
            }
            ParticleFloatField::AngularVelocity => settings.appearance.angular_velocity = value,
            ParticleFloatField::AngularVelocityRandomness => {
                settings.appearance.angular_velocity_randomness = value
            }
            ParticleFloatField::VelocityInheritance => {
                settings.velocity.velocity_inheritance = value
            }
            ParticleFloatField::NoiseStrength => settings.forces.noise_strength = value,
            ParticleFloatField::NoiseScale => settings.forces.noise_scale = value,
            ParticleFloatField::NoiseSpeed => settings.forces.noise_speed = value,
            ParticleFloatField::ForceRadius => settings.forces.force_radius = value,
            ParticleFloatField::ForceStrength => settings.forces.force_strength = value,
            ParticleFloatField::ForceFalloff => settings.forces.force_falloff = value,
            ParticleFloatField::VectorFieldStrength => {
                settings.forces.vector_field_strength = value
            }
            ParticleFloatField::VectorFieldScale => settings.forces.vector_field_scale = value,
            ParticleFloatField::VectorFieldScrollSpeed => {
                settings.forces.vector_field_scroll_speed = value
            }
            ParticleFloatField::CollisionPlaneY => settings.collision.collision_plane_y = value,
            ParticleFloatField::CollisionRestitution => {
                settings.collision.collision_restitution = value
            }
            ParticleFloatField::CollisionDamping => settings.collision.collision_damping = value,
            ParticleFloatField::RibbonWidthScale => settings.trails.ribbon_width_scale = value,
            ParticleFloatField::RibbonTailWidthScale => {
                settings.trails.ribbon_tail_width_scale = value
            }
            ParticleFloatField::RibbonTailAlphaScale => {
                settings.trails.ribbon_tail_alpha_scale = value
            }
            ParticleFloatField::RibbonMaxSegmentLength => {
                settings.trails.ribbon_max_segment_length = value
            }
            ParticleFloatField::RibbonJoinOverlapScale => {
                settings.trails.ribbon_join_overlap_scale = value
            }
            ParticleFloatField::RibbonTextureTiling => {
                settings.trails.ribbon_texture_tiling = value
            }
            ParticleFloatField::RibbonTextureOffset => {
                settings.trails.ribbon_texture_offset = value
            }
            ParticleFloatField::VelocityStretchScale => {
                settings.renderer.velocity_stretch_scale = value
            }
            ParticleFloatField::VelocityStretchMax => {
                settings.renderer.velocity_stretch_max = value
            }
            ParticleFloatField::MaxRenderDistance => settings.renderer.max_render_distance = value,
            ParticleFloatField::RenderDistanceFadeRange => {
                settings.renderer.render_distance_fade_range = value
            }
            ParticleFloatField::RenderLodStartDistance => {
                settings.renderer.render_lod_start_distance = value
            }
            ParticleFloatField::RenderLodEndDistance => {
                settings.renderer.render_lod_end_distance = value
            }
            ParticleFloatField::RenderLodMinParticleScale => {
                settings.renderer.render_lod_min_particle_scale = value
            }
            ParticleFloatField::RenderBoundsRadius => {
                settings.renderer.render_bounds_radius = value
            }
            ParticleFloatField::FrameRate => settings.texture_sheet.frame_rate = value,
            ParticleFloatField::TrailLength => settings.trails.trail_length = value,
            ParticleFloatField::TrailEndSizeScale => settings.trails.trail_end_size_scale = value,
            ParticleFloatField::TrailEndAlphaScale => settings.trails.trail_end_alpha_scale = value,
        }
    }
}

/// `WritableKeyPath<ParticleEmitter, Int>` cases used by the emitter form.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ParticleIntField {
    BurstCount,
    MaxSpawnedParticlesPerFrame,
    MaxRenderedParticles,
    SubEmitterBurstCount,
    SubEmitterMaxDepth,
    WorkgroupSize,
    SheetColumns,
    SheetRows,
    SheetFrames,
    SheetStartFrame,
    SheetRandomness,
    RibbonSmoothingSegments,
    TrailSegments,
}

impl ParticleIntField {
    fn get(self, emitter: &ParticleEmitter) -> i64 {
        let settings = &emitter.settings;
        match self {
            ParticleIntField::BurstCount => settings.emission.burst_count,
            ParticleIntField::MaxSpawnedParticlesPerFrame => {
                settings.emission.max_spawned_particles_per_frame
            }
            ParticleIntField::MaxRenderedParticles => settings.emission.max_rendered_particles,
            ParticleIntField::SubEmitterBurstCount => settings.sub_emitters.legacy_burst_count,
            ParticleIntField::SubEmitterMaxDepth => settings.sub_emitters.legacy_max_depth,
            ParticleIntField::WorkgroupSize => settings.gpu_simulation.workgroup_size,
            ParticleIntField::SheetColumns => settings.texture_sheet.columns,
            ParticleIntField::SheetRows => settings.texture_sheet.rows,
            ParticleIntField::SheetFrames => settings.texture_sheet.frame_count,
            ParticleIntField::SheetStartFrame => settings.texture_sheet.start_frame,
            ParticleIntField::SheetRandomness => settings.texture_sheet.frame_randomness,
            ParticleIntField::RibbonSmoothingSegments => settings.trails.ribbon_smoothing_segments,
            ParticleIntField::TrailSegments => settings.trails.trail_segments,
        }
    }

    fn set(self, emitter: &mut ParticleEmitter, value: i64) {
        let settings = &mut emitter.settings;
        match self {
            ParticleIntField::BurstCount => settings.emission.burst_count = value,
            ParticleIntField::MaxSpawnedParticlesPerFrame => {
                settings.emission.max_spawned_particles_per_frame = value
            }
            ParticleIntField::MaxRenderedParticles => {
                settings.emission.max_rendered_particles = value
            }
            ParticleIntField::SubEmitterBurstCount => {
                settings.sub_emitters.legacy_burst_count = value
            }
            ParticleIntField::SubEmitterMaxDepth => settings.sub_emitters.legacy_max_depth = value,
            ParticleIntField::WorkgroupSize => settings.gpu_simulation.workgroup_size = value,
            ParticleIntField::SheetColumns => settings.texture_sheet.columns = value,
            ParticleIntField::SheetRows => settings.texture_sheet.rows = value,
            ParticleIntField::SheetFrames => settings.texture_sheet.frame_count = value,
            ParticleIntField::SheetStartFrame => settings.texture_sheet.start_frame = value,
            ParticleIntField::SheetRandomness => settings.texture_sheet.frame_randomness = value,
            ParticleIntField::RibbonSmoothingSegments => {
                settings.trails.ribbon_smoothing_segments = value
            }
            ParticleIntField::TrailSegments => settings.trails.trail_segments = value,
        }
    }
}

/// `WritableKeyPath<ParticleEmitter, SIMD3<Float>>` cases used by the emitter form.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ParticleVectorField {
    SubEmitterStartVelocity,
    SubEmitterVelocityRandomness,
    ForceCenter,
    ForceAxis,
    VectorFieldDirection,
}

impl ParticleVectorField {
    fn get(self, emitter: &ParticleEmitter) -> Float3 {
        let settings = &emitter.settings;
        match self {
            ParticleVectorField::SubEmitterStartVelocity => {
                settings.sub_emitters.legacy_start_velocity
            }
            ParticleVectorField::SubEmitterVelocityRandomness => {
                settings.sub_emitters.legacy_velocity_randomness
            }
            ParticleVectorField::ForceCenter => settings.forces.force_center,
            ParticleVectorField::ForceAxis => settings.forces.force_axis,
            ParticleVectorField::VectorFieldDirection => settings.forces.vector_field_direction,
        }
    }

    fn set(self, emitter: &mut ParticleEmitter, value: Float3) {
        let settings = &mut emitter.settings;
        match self {
            ParticleVectorField::SubEmitterStartVelocity => {
                settings.sub_emitters.legacy_start_velocity = value
            }
            ParticleVectorField::SubEmitterVelocityRandomness => {
                settings.sub_emitters.legacy_velocity_randomness = value
            }
            ParticleVectorField::ForceCenter => settings.forces.force_center = value,
            ParticleVectorField::ForceAxis => settings.forces.force_axis = value,
            ParticleVectorField::VectorFieldDirection => {
                settings.forces.vector_field_direction = value
            }
        }
    }
}

fn vector_axis(value: Float3, axis: usize) -> f32 {
    match axis {
        0 => value.x,
        1 => value.y,
        _ => value.z,
    }
}

fn set_vector_axis(value: &mut Float3, axis: usize, component: f32) {
    match axis {
        0 => value.x = component,
        1 => value.y = component,
        _ => value.z = component,
    }
}

impl EditorSceneAdapter {
    pub(crate) fn particle_gpu_status_label(&self, entity: EntityID) -> String {
        let Some(emitter) = self.scene().component::<ParticleEmitter>(entity) else {
            return localized("No emitter");
        };
        let plan = emitter.gpu_simulation_plan();
        match plan.status {
            ParticleGPUSimulationPlanStatus::Disabled => localized("CPU"),
            ParticleGPUSimulationPlanStatus::Supported => format!(
                "{} ({}x{})",
                localized("Supported"),
                plan.dispatch_workgroups,
                plan.workgroup_size
            ),
            ParticleGPUSimulationPlanStatus::FallbackToCpu => format!(
                "{}: {}",
                localized("CPU fallback"),
                Self::particle_gpu_unsupported_reason_list(&plan.unsupported_reasons)
            ),
            ParticleGPUSimulationPlanStatus::RequiredButUnsupported => format!(
                "{}: {}",
                localized("Unsupported"),
                Self::particle_gpu_unsupported_reason_list(&plan.unsupported_reasons)
            ),
        }
    }

    fn particle_gpu_unsupported_reason_list(
        reasons: &[ParticleGPUSimulationUnsupportedReason],
    ) -> String {
        if reasons.is_empty() {
            return localized("None");
        }
        reasons
            .iter()
            .map(|reason| Self::particle_gpu_unsupported_reason_label(*reason))
            .collect::<Vec<_>>()
            .join(", ")
    }

    fn particle_gpu_unsupported_reason_label(
        reason: ParticleGPUSimulationUnsupportedReason,
    ) -> String {
        match reason {
            ParticleGPUSimulationUnsupportedReason::BackendCpu => localized("CPU backend"),
            ParticleGPUSimulationUnsupportedReason::NoParticleCapacity => localized("no capacity"),
            ParticleGPUSimulationUnsupportedReason::EventSubEmitters => localized("sub-emitters"),
            ParticleGPUSimulationUnsupportedReason::DistanceEmission => {
                localized("distance emission")
            }
            ParticleGPUSimulationUnsupportedReason::Noise => localized("noise"),
            ParticleGPUSimulationUnsupportedReason::ForceFields => localized("force fields"),
            ParticleGPUSimulationUnsupportedReason::Collisions => localized("collisions"),
            ParticleGPUSimulationUnsupportedReason::AngularVelocity => {
                localized("angular velocity")
            }
        }
    }

    /// Applies `mutate` to a copy of the emitter and submits it as a whole-component update.
    fn update_particle_emitter(
        &self,
        entity: EntityID,
        summary: &str,
        mutate: impl FnOnce(&mut ParticleEmitter),
    ) {
        let Some(mut emitter) = self.scene().component::<ParticleEmitter>(entity) else {
            return;
        };
        mutate(&mut emitter);
        let registry = self.scene().component_registry().clone();
        let mutation =
            SceneMutation::component_data(entity.raw_value(), "particleEmitter", emitter, registry);
        let _ = self.apply_scene_transaction(
            "scene.set_particle_emitter",
            summary,
            vec![entity.raw_value()],
            vec![mutation],
        );
    }

    pub(crate) fn particle_module_stack_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleModuleStack> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.module_stack())
                    .unwrap_or_default()
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.module_stack())
                    == Some(next.clone())
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle module stack", |emitter| {
                    emitter.apply(next);
                });
            },
        )
    }

    pub(crate) fn particle_bool_binding(
        &self,
        entity: EntityID,
        field: ParticleBoolField,
        summary: &str,
    ) -> Binding<bool> {
        let getter = self.clone();
        let setter = self.clone();
        let summary = summary.to_string();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter))
                    .unwrap_or(false)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter))
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, &summary, |emitter| {
                    field.set(emitter, next);
                });
            },
        )
    }

    pub(crate) fn particle_float_binding(
        &self,
        entity: EntityID,
        field: ParticleFloatField,
        summary: &str,
    ) -> Binding<f32> {
        let getter = self.clone();
        let setter = self.clone();
        let summary = summary.to_string();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter))
                    .unwrap_or(0.0)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter))
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, &summary, |emitter| {
                    field.set(emitter, next);
                });
            },
        )
    }

    pub(crate) fn particle_max_binding(&self, entity: EntityID) -> Binding<f32> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.emission.max_particles as f32)
                    .unwrap_or(0.0)
            },
            move |next| {
                let value = swift_rounded_i64(next);
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.emission.max_particles)
                    == Some(value)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update max particles", |emitter| {
                    emitter.settings.emission.max_particles = value;
                });
            },
        )
    }

    pub(crate) fn particle_int_binding(
        &self,
        entity: EntityID,
        field: ParticleIntField,
        summary: &str,
    ) -> Binding<f32> {
        let getter = self.clone();
        let setter = self.clone();
        let summary = summary.to_string();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter) as f32)
                    .unwrap_or(0.0)
            },
            move |next| {
                let value = swift_rounded_i64(next).max(0);
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter))
                    == Some(value)
                {
                    return;
                }
                setter.update_particle_emitter(entity, &summary, |emitter| {
                    field.set(emitter, value);
                });
            },
        )
    }

    pub(crate) fn particle_clamped_int_binding(
        &self,
        entity: EntityID,
        field: ParticleIntField,
        minimum: i64,
        maximum: i64,
        summary: &str,
    ) -> Binding<f32> {
        let getter = self.clone();
        let setter = self.clone();
        let summary = summary.to_string();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter) as f32)
                    .unwrap_or(minimum as f32)
            },
            move |next| {
                let lower = minimum.min(maximum);
                let upper = minimum.max(maximum);
                let value = swift_rounded_i64(next).clamp(lower, upper);
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| field.get(&emitter))
                    == Some(value)
                {
                    return;
                }
                setter.update_particle_emitter(entity, &summary, |emitter| {
                    field.set(emitter, value);
                });
            },
        )
    }

    pub(crate) fn particle_shape_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleEmissionShape> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.shape.emission_shape)
                    .unwrap_or(ParticleEmissionShape::Sphere)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.shape.emission_shape)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update particle emission shape",
                    |emitter| {
                        emitter.settings.shape.emission_shape = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_box_extents_binding(
        &self,
        entity: EntityID,
        axis: usize,
    ) -> Binding<f32> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| vector_axis(emitter.settings.shape.box_half_extents, axis))
                    .unwrap_or(0.0)
            },
            move |next| {
                let value = next.max(0.0);
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| vector_axis(emitter.settings.shape.box_half_extents, axis))
                    == Some(value)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle box extents", |emitter| {
                    set_vector_axis(&mut emitter.settings.shape.box_half_extents, axis, value);
                });
            },
        )
    }

    pub(crate) fn particle_collision_mode_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleCollisionMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.collision.collision_mode)
                    .unwrap_or(ParticleCollisionMode::None)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.collision.collision_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update particle collision mode",
                    |emitter| {
                        emitter.settings.collision.collision_mode = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_force_mode_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleForceMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.forces.force_mode)
                    .unwrap_or(ParticleForceMode::None)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.forces.force_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle force mode", |emitter| {
                    emitter.settings.forces.force_mode = next;
                });
            },
        )
    }

    pub(crate) fn particle_vector_field_mode_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleVectorFieldMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.forces.vector_field_mode)
                    .unwrap_or(ParticleVectorFieldMode::None)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.forces.vector_field_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update particle vector field mode",
                    |emitter| {
                        emitter.settings.forces.vector_field_mode = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_sub_emitter_trigger_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleSubEmitterTrigger> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.sub_emitters.legacy_trigger)
                    .unwrap_or(ParticleSubEmitterTrigger::None)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.sub_emitters.legacy_trigger)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update sub-emitter trigger", |emitter| {
                    emitter.settings.sub_emitters.legacy_trigger = next;
                });
            },
        )
    }

    pub(crate) fn particle_sub_emitters_binding(
        &self,
        entity: EntityID,
    ) -> Binding<Vec<ParticleSubEmitter>> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.sub_emitters.rules)
                    .unwrap_or_default()
            },
            move |next| {
                let sanitized: Vec<ParticleSubEmitter> = next
                    .into_iter()
                    .map(sanitized_particle_sub_emitter)
                    .collect();
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.sub_emitters.rules)
                    == Some(sanitized.clone())
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle sub-emitters", |emitter| {
                    emitter.settings.sub_emitters.rules = sanitized;
                });
            },
        )
    }

    pub(crate) fn particle_vector_binding(
        &self,
        entity: EntityID,
        field: ParticleVectorField,
        axis: usize,
        summary: &str,
    ) -> Binding<f32> {
        let getter = self.clone();
        let setter = self.clone();
        let summary = summary.to_string();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| vector_axis(field.get(&emitter), axis))
                    .unwrap_or(0.0)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| vector_axis(field.get(&emitter), axis))
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, &summary, |emitter| {
                    let mut value = field.get(emitter);
                    set_vector_axis(&mut value, axis, next);
                    field.set(emitter, value);
                });
            },
        )
    }

    pub(crate) fn particle_simulation_space_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleSimulationSpace> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.gpu_simulation.simulation_space)
                    .unwrap_or(ParticleSimulationSpace::Local)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.gpu_simulation.simulation_space)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update particle simulation space",
                    |emitter| {
                        emitter.settings.gpu_simulation.simulation_space = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_simulation_backend_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleSimulationBackend> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.gpu_simulation.simulation_backend)
                    .unwrap_or(ParticleSimulationBackend::Cpu)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.gpu_simulation.simulation_backend)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update particle simulation backend",
                    |emitter| {
                        emitter.settings.gpu_simulation.simulation_backend = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_curve_binding(
        &self,
        entity: EntityID,
        key: ParticleCurveField,
        summary: &str,
    ) -> Binding<ParticleCurve> {
        let getter = self.clone();
        let setter = self.clone();
        let summary = summary.to_string();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| key.get(&emitter))
                    .unwrap_or(ParticleCurve::Linear)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| key.get(&emitter))
                    == Some(next.clone())
                {
                    return;
                }
                setter.update_particle_emitter(entity, &summary, |emitter| {
                    key.set(emitter, next.clone());
                });
            },
        )
    }

    pub(crate) fn particle_blend_mode_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleBlendMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.appearance.blend_mode)
                    .unwrap_or(ParticleBlendMode::Alpha)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.appearance.blend_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle blend mode", |emitter| {
                    emitter.settings.appearance.blend_mode = next;
                });
            },
        )
    }

    pub(crate) fn particle_render_mode_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleRenderMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.render_mode)
                    .unwrap_or(ParticleRenderMode::Billboard)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.render_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle render mode", |emitter| {
                    emitter.settings.renderer.render_mode = next;
                });
            },
        )
    }

    pub(crate) fn particle_sort_mode_binding(&self, entity: EntityID) -> Binding<ParticleSortMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.sort_mode)
                    .unwrap_or(ParticleSortMode::DistanceDescending)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.sort_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle sort mode", |emitter| {
                    emitter.settings.renderer.sort_mode = next;
                });
            },
        )
    }

    pub(crate) fn particle_texture_sheet_playback_mode_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleTextureSheetPlaybackMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.texture_sheet.playback_mode)
                    .unwrap_or(ParticleTextureSheetPlaybackMode::Automatic)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.texture_sheet.playback_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update texture sheet playback",
                    |emitter| {
                        emitter.settings.texture_sheet.playback_mode = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_render_alignment_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleRenderAlignment> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.render_alignment)
                    .unwrap_or(ParticleRenderAlignment::Billboard)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.render_alignment)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update particle render alignment",
                    |emitter| {
                        emitter.settings.renderer.render_alignment = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_render_bounds_mode_binding(
        &self,
        entity: EntityID,
    ) -> Binding<ParticleRenderBoundsMode> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.render_bounds_mode)
                    .unwrap_or(ParticleRenderBoundsMode::Disabled)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| emitter.settings.renderer.render_bounds_mode)
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(
                    entity,
                    "Update particle render bounds mode",
                    |emitter| {
                        emitter.settings.renderer.render_bounds_mode = next;
                    },
                );
            },
        )
    }

    pub(crate) fn particle_texture_asset_binding(
        &self,
        entity: EntityID,
    ) -> Binding<Option<EditorInspectorAssetRef>> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                let emitter = getter.scene().component::<ParticleEmitter>(entity)?;
                if let Some(asset_id) = emitter.settings.texture_sheet.texture_asset_id.as_ref()
                    && let Some(asset) = EditorAssetCatalog::asset_for(asset_id)
                {
                    return Some(EditorInspectorAssetRef::with_options(
                        asset.id,
                        asset.name,
                        Some(asset.relative_path),
                        asset.kind.scene_kind_label(),
                        if asset.kind.is_texture() {
                            Some(asset.absolute_path)
                        } else {
                            None
                        },
                    ));
                }
                if let Some(texture_path) = emitter.settings.texture_sheet.texture_path.as_ref()
                    && !texture_path.is_empty()
                {
                    let stem = Path::new(texture_path)
                        .file_stem()
                        .map(|stem| stem.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    return Some(EditorInspectorAssetRef::with_options(
                        emitter
                            .settings
                            .texture_sheet
                            .texture_asset_id
                            .clone()
                            .unwrap_or_else(|| texture_path.clone()),
                        stem,
                        Some(texture_path.clone()),
                        ImportableAssetKind::Png.scene_kind_label(),
                        Some(texture_path.clone()),
                    ));
                }
                None
            },
            move |next| {
                let Some(current) = setter.scene().component::<ParticleEmitter>(entity) else {
                    return;
                };
                let resolved: (Option<String>, Option<String>) = match next {
                    Some(next) => {
                        if let Some(asset) = EditorAssetCatalog::asset_for(&next.id)
                            && asset.kind.is_texture()
                        {
                            (Some(asset.id), Some(asset.absolute_path))
                        } else if next.kind == ImportableAssetKind::Png.scene_kind_label() {
                            let path = next
                                .subtitle
                                .as_deref()
                                .map(str::trim)
                                .filter(|path| !path.is_empty())
                                .map(str::to_string);
                            (Some(next.id), path)
                        } else {
                            return;
                        }
                    }
                    None => (None, None),
                };
                if current.settings.texture_sheet.texture_asset_id == resolved.0
                    && current.settings.texture_sheet.texture_path == resolved.1
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle texture", |emitter| {
                    emitter.settings.texture_sheet.texture_asset_id = resolved.0;
                    emitter.settings.texture_sheet.texture_path = resolved.1;
                });
            },
        )
    }

    pub(crate) fn particle_gravity_binding(&self, entity: EntityID, axis: usize) -> Binding<f32> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| vector_axis(emitter.settings.forces.gravity, axis))
                    .unwrap_or(0.0)
            },
            move |next| {
                if setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| vector_axis(emitter.settings.forces.gravity, axis))
                    == Some(next)
                {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle gravity", |emitter| {
                    set_vector_axis(&mut emitter.settings.forces.gravity, axis, next);
                });
            },
        )
    }

    pub(crate) fn particle_sub_emitter_color_binding(
        &self,
        entity: EntityID,
        is_start: bool,
    ) -> Binding<Color> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                let color = getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| {
                        if is_start {
                            emitter.settings.sub_emitters.legacy_start_color
                        } else {
                            emitter.settings.sub_emitters.legacy_end_color
                        }
                    })
                    .unwrap_or(Float4::new(1.0, 1.0, 1.0, 1.0));
                Color {
                    r: color.x,
                    g: color.y,
                    b: color.z,
                    a: color.w,
                }
            },
            move |next| {
                let value = Float4::new(
                    next.r.clamp(0.0, 1.0),
                    next.g.clamp(0.0, 1.0),
                    next.b.clamp(0.0, 1.0),
                    next.a.clamp(0.0, 1.0),
                );
                let current = setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| {
                        if is_start {
                            emitter.settings.sub_emitters.legacy_start_color
                        } else {
                            emitter.settings.sub_emitters.legacy_end_color
                        }
                    });
                if current == Some(value) {
                    return;
                }
                setter.update_particle_emitter(entity, "Update sub-emitter color", |emitter| {
                    if is_start {
                        emitter.settings.sub_emitters.legacy_start_color = value;
                    } else {
                        emitter.settings.sub_emitters.legacy_end_color = value;
                    }
                });
            },
        )
    }

    pub(crate) fn particle_color_binding(
        &self,
        entity: EntityID,
        is_start: bool,
    ) -> Binding<Color> {
        let getter = self.clone();
        let setter = self.clone();
        Binding::new(
            move || {
                let color = getter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| {
                        if is_start {
                            emitter.settings.appearance.start_color
                        } else {
                            emitter.settings.appearance.end_color
                        }
                    })
                    .unwrap_or(Float4::new(1.0, 1.0, 1.0, 1.0));
                Color {
                    r: color.x,
                    g: color.y,
                    b: color.z,
                    a: color.w,
                }
            },
            move |next| {
                let value = Float4::new(
                    next.r.clamp(0.0, 1.0),
                    next.g.clamp(0.0, 1.0),
                    next.b.clamp(0.0, 1.0),
                    next.a.clamp(0.0, 1.0),
                );
                let current = setter
                    .scene()
                    .component::<ParticleEmitter>(entity)
                    .map(|emitter| {
                        if is_start {
                            emitter.settings.appearance.start_color
                        } else {
                            emitter.settings.appearance.end_color
                        }
                    });
                if current == Some(value) {
                    return;
                }
                setter.update_particle_emitter(entity, "Update particle color", |emitter| {
                    if is_start {
                        emitter.settings.appearance.start_color = value;
                    } else {
                        emitter.settings.appearance.end_color = value;
                    }
                });
            },
        )
    }
}

/// `WritableKeyPath<ParticleEmitter, ParticleCurve>` cases used by the emitter form.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ParticleCurveField {
    EmissionRate,
    DistanceEmissionRate,
    Size,
    Color,
}

impl ParticleCurveField {
    fn get(self, emitter: &ParticleEmitter) -> ParticleCurve {
        match self {
            ParticleCurveField::EmissionRate => {
                emitter.settings.emission.emission_rate_curve.clone()
            }
            ParticleCurveField::DistanceEmissionRate => emitter
                .settings
                .emission
                .distance_emission_rate_curve
                .clone(),
            ParticleCurveField::Size => emitter.settings.appearance.size_curve.clone(),
            ParticleCurveField::Color => emitter.settings.appearance.color_curve.clone(),
        }
    }

    fn set(self, emitter: &mut ParticleEmitter, value: ParticleCurve) {
        match self {
            ParticleCurveField::EmissionRate => {
                emitter.settings.emission.emission_rate_curve = value
            }
            ParticleCurveField::DistanceEmissionRate => {
                emitter.settings.emission.distance_emission_rate_curve = value
            }
            ParticleCurveField::Size => emitter.settings.appearance.size_curve = value,
            ParticleCurveField::Color => emitter.settings.appearance.color_curve = value,
        }
    }
}

fn sanitized_particle_sub_emitter(rule: ParticleSubEmitter) -> ParticleSubEmitter {
    ParticleSubEmitter::new(
        rule.trigger,
        rule.burst_count,
        rule.probability,
        rule.max_depth,
        rule.inherit_velocity,
        rule.lifetime,
        rule.start_velocity,
        rule.velocity_randomness,
        rule.start_size,
        rule.end_size,
        rule.start_color,
        rule.end_color,
    )
}

/// Swift's `Int(value.rounded())` for a `Float` binding, saturating outside `i64`.
fn swift_rounded_i64(value: f32) -> i64 {
    if !value.is_finite() {
        return 0;
    }
    let rounded = value.round();
    if rounded >= i64::MAX as f32 {
        i64::MAX
    } else if rounded <= i64::MIN as f32 {
        i64::MIN
    } else {
        rounded as i64
    }
}

/// `acceptedKinds` for the texture field (PNG only), exposed for the section.
pub(crate) fn particle_texture_accepted_kinds() -> BTreeSet<String> {
    let mut kinds = BTreeSet::new();
    kinds.insert(ImportableAssetKind::Png.scene_kind_label().to_string());
    kinds
}
