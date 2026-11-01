//! Ported from `Engine/Tests/SceneRuntimeTests/ParticleTests.swift`.
//!
//! Swift builds emitters with `ParticleEmitter(settings: .init { … })` and calls
//! `advance(deltaTime:)`/`emit(_:)` with defaulted `worldTransform`/`options`
//! arguments; the helpers below expand those defaults explicitly. The frame index
//! that Swift's `SceneRuntime.tick(deltaTime:)` does not take is always 0 here.
//! Swift's memberwise stat initializers default every unlisted field to zero, so
//! `frame_stats(…)` starts from the clamped empty stats and assigns the fields a
//! test names.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_length,
};

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::particles::particle_curve::{ParticleCurve, ParticleCurveKeyframe};
use crate::particles::particle_events::{ParticleEvent, ParticleSubEmitter};
use crate::particles::particle_gpu_simulation_plan::{
    ParticleGPUSimulationPlan, ParticleGPUSimulationPlanStatus,
};
use crate::particles::particle_modules::{
    ParticleEmitterModuleSettings, ParticleModuleStack, ParticleModuleStage,
};
use crate::particles::particle_scalability::{
    ParticleRuntimePressureLevel, ParticleScalabilityPolicyResource,
    ParticleScalabilityPressureReason, ParticleScalabilityResource,
    ParticleScalabilityStateResource,
};
use crate::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use crate::particles::particle_stats::{ParticleEmitterFrameStats, ParticleFrameStatsResource};
use crate::particles::particle_types::{
    Particle, ParticleAdvanceOptions, ParticleBlendMode, ParticleCollisionMode,
    ParticleEmissionShape, ParticleForceMode, ParticleRenderAlignment, ParticleRenderBoundsMode,
    ParticleRenderMode, ParticleSimulationBackend, ParticleSimulationSpace, ParticleSortMode,
    ParticleSubEmitterTrigger, ParticleTextureSheetPlaybackMode, ParticleVectorFieldMode,
};
use crate::runtime_world::{LocalTransform, WorldTransform};
use crate::scene_runtime::SceneRuntime;

/// Swift's `ParticleEmitter(settings: .init { … })`; the emitter normalizes on
/// construction exactly like Swift's initializer.
fn emitter_with(configure: impl FnOnce(&mut ParticleEmitterSettings)) -> ParticleEmitter {
    let mut settings = ParticleEmitterSettings::default();
    configure(&mut settings);
    ParticleEmitter::new(settings)
}

/// Swift's `advance(deltaTime:)` defaults (`worldTransform: nil`, default options).
fn advance(emitter: &mut ParticleEmitter, delta_time: f64) {
    emitter.advance(delta_time, None, &ParticleAdvanceOptions::default());
}

/// Swift's `advance(deltaTime:worldTransform:)` with default advance options.
fn advance_within(emitter: &mut ParticleEmitter, delta_time: f64, transform: Float4x4) {
    emitter.advance(
        delta_time,
        Some(transform),
        &ParticleAdvanceOptions::default(),
    );
}

/// `var matrix = matrix_identity_float4x4; matrix.columns.3 = …`.
fn translated(x: f32, y: f32, z: f32) -> Float4x4 {
    let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
    matrix.columns[3] = Float4::new(x, y, z, 1.0);
    matrix
}

/// The suite's `editModule(_:id:)` helper: the missing module is a test failure.
fn edit_module(
    stack: &mut ParticleModuleStack,
    id: &str,
    edit: impl FnOnce(&mut ParticleEmitterModuleSettings),
) {
    let index = stack
        .modules
        .iter()
        .position(|module| module.id == id)
        .unwrap_or_else(|| panic!("missing module '{id}'"));
    edit(&mut stack.modules[index].settings);
}

fn module_ids(stack: &ParticleModuleStack) -> Vec<String> {
    stack
        .modules
        .iter()
        .map(|module| module.id.clone())
        .collect()
}

fn issue_codes(stack: &ParticleModuleStack) -> Vec<String> {
    stack
        .validation_issues()
        .into_iter()
        .map(|issue| issue.code)
        .collect()
}

fn has_code(codes: &[String], code: &str) -> bool {
    codes.iter().any(|candidate| candidate == code)
}

fn particle_with_generation(emitter: &ParticleEmitter, generation: u8) -> Option<Particle> {
    emitter
        .particles()
        .iter()
        .find(|particle| particle.generation == generation)
        .copied()
}

/// Swift's memberwise `ParticleEmitterFrameStats(…)` with every unlisted field
/// left at its zero default.
fn frame_stats(
    configure: impl FnOnce(&mut ParticleEmitterFrameStats),
) -> ParticleEmitterFrameStats {
    let mut stats = ParticleEmitterFrameStats::default();
    configure(&mut stats);
    stats
}

fn aggregate_stats(emitter_stats: Vec<ParticleEmitterFrameStats>) -> ParticleFrameStatsResource {
    ParticleFrameStatsResource::new(0.0, emitter_stats, BTreeMap::new(), 0, 0, 0, 0, 0, 0)
}

/// Clearing an emitter preserves authoring and the next random sample.
#[test]
fn clear_preserves_configuration_and_random_stream() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 16;
        settings.appearance.lifetime = 5.0;
        settings.shape.spawn_radius = 2.0;
        settings.velocity.velocity_randomness = Float3::new(1.0, 2.0, 3.0);
        settings.emission.seed = 73;
    });
    emitter.emit(2, None);
    advance(&mut emitter, 0.1);
    let configuration = emitter.module_stack();
    let mut continued = emitter.clone();

    emitter.clear();

    assert!(emitter.particles().is_empty());
    assert!(emitter.last_frame_spawned_particles().is_empty());
    assert!(emitter.last_frame_events().is_empty());
    assert_eq!(
        emitter.last_frame_stats(),
        ParticleEmitterFrameStats::empty()
    );
    assert_eq!(emitter.module_stack(), configuration);
    assert_eq!(continued.alive_count(), 2);

    emitter.emit(1, None);
    continued.emit(1, None);
    assert_eq!(emitter.particles().first(), continued.particles().last());
}

/// Module-based initialization creates an independent seeded simulation.
#[test]
fn module_initialization_starts_fresh_simulation() {
    let mut source = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 16;
        settings.appearance.lifetime = 5.0;
        settings.shape.spawn_radius = 2.0;
        settings.velocity.velocity_randomness = Float3::new(1.0, 2.0, 3.0);
        settings.emission.seed = 73;
    });
    let configuration = source.module_stack();
    source.emit(3, None);
    let mut restored = ParticleEmitter::from_module_stack(&configuration);

    assert_eq!(restored.alive_count(), 0);
    assert_eq!(
        restored.last_frame_stats(),
        ParticleEmitterFrameStats::empty()
    );
    assert_eq!(restored.module_stack(), configuration);

    restored.emit(3, None);
    assert_eq!(restored.particles(), source.particles());
    restored.clear();
    assert_eq!(source.alive_count(), 3);
}

/// Module stack mirrors and applies grouped emitter configuration.
#[test]
fn module_stack_mirrors_and_applies_grouped_emitter_configuration() {
    let emitter = emitter_with(|settings| {
        settings.emission.looping = false;
        settings.emission.duration = 4.0;
        settings.emission.emission_rate = 12.0;
        settings.emission.distance_emission_rate = 3.0;
        settings.emission.burst_count = 2;
        settings.emission.max_particles = 128;
        settings.emission.max_spawned_particles_per_frame = 16;
        settings.emission.max_rendered_particles = 32;
        settings.appearance.lifetime = 1.5;
        settings.sub_emitters.rules = vec![ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::Death,
            2,
            1.0,
            1,
            0.0,
            0.4,
            Float3::new(1.0, 0.0, 0.0),
            Float3::ZERO,
            0.25,
            0.0,
            Float4::new(1.0, 1.0, 1.0, 1.0),
            Float4::new(1.0, 1.0, 1.0, 0.0),
        )];
        settings.shape.origin_offset = Float3::new(0.5, 1.0, -0.5);
        settings.shape.spawn_radius = 2.0;
        settings.shape.emission_shape = ParticleEmissionShape::Cone;
        settings.shape.cone_radius = 0.75;
        settings.shape.cone_height = 3.0;
        settings.velocity.start_velocity = Float3::new(1.0, 2.0, 3.0);
        settings.velocity.velocity_randomness = Float3::new(0.1, 0.2, 0.3);
        settings.velocity.velocity_inheritance = 0.5;
        settings.forces.gravity = Float3::new(0.0, -2.0, 0.0);
        settings.forces.noise_strength = 1.25;
        settings.forces.force_mode = ParticleForceMode::Radial;
        settings.forces.force_radius = 4.0;
        settings.forces.force_strength = 6.0;
        settings.forces.vector_field_mode = ParticleVectorFieldMode::Curl;
        settings.forces.vector_field_strength = 2.0;
        settings.collision.collision_mode = ParticleCollisionMode::WorldPlane;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
        settings.gpu_simulation.workgroup_size = 128;
        settings.collision.collision_restitution = 0.8;
        settings.collision.collision_damping = 0.2;
        settings.appearance.start_size = 0.5;
        settings.appearance.end_size = 0.1;
        settings.appearance.size_randomness = 0.3;
        settings.appearance.blend_mode = ParticleBlendMode::Additive;
        settings.renderer.render_mode = ParticleRenderMode::Ribbon;
        settings.renderer.sort_mode = ParticleSortMode::YoungestFirst;
        settings.renderer.render_alignment = ParticleRenderAlignment::Velocity;
        settings.renderer.velocity_stretch_scale = 0.4;
        settings.renderer.max_render_distance = 80.0;
        settings.texture_sheet.texture_asset_id = Some("texture-smoke".to_string());
        settings.texture_sheet.texture_path = Some("/tmp/smoke.png".to_string());
        settings.texture_sheet.columns = 4;
        settings.texture_sheet.rows = 2;
        settings.texture_sheet.frame_count = 7;
        settings.texture_sheet.frame_rate = 12.0;
        settings.texture_sheet.playback_mode = ParticleTextureSheetPlaybackMode::Loop;
        settings.texture_sheet.start_frame = 3;
        settings.texture_sheet.frame_randomness = 2;
        settings.trails.trail_length = 0.75;
        settings.trails.trail_segments = 5;
        settings.emission.seed = 987_654_321;
    });

    let mut stack = emitter.module_stack();

    assert_eq!(stack.version, ParticleModuleStack::CURRENT_VERSION);
    let expected_ids: Vec<String> = ParticleModuleStack::DEFAULT_MODULE_IDS
        .iter()
        .map(|id| id.to_string())
        .collect();
    assert_eq!(module_ids(&stack), expected_ids);

    let emission = stack
        .modules
        .iter()
        .find(|module| module.id == "emission")
        .expect("emission module");
    match &emission.settings {
        ParticleEmitterModuleSettings::Emission(settings) => {
            assert_eq!(settings.emission_rate, 12.0);
            assert_eq!(settings.distance_emission_rate, 3.0);
            assert_eq!(settings.max_spawned_particles_per_frame, 16);
            assert_eq!(settings.max_rendered_particles, 32);
            assert_eq!(settings.seed, 987_654_321);
        }
        _ => panic!("expected emission module settings"),
    }

    let texture_sheet = stack
        .modules
        .iter()
        .find(|module| module.id == "textureSheet")
        .expect("texture sheet module");
    match &texture_sheet.settings {
        ParticleEmitterModuleSettings::TextureSheet(settings) => {
            assert_eq!(settings.texture_asset_id.as_deref(), Some("texture-smoke"));
            assert_eq!(settings.columns, 4);
            assert_eq!(settings.rows, 2);
            assert_eq!(
                settings.playback_mode,
                ParticleTextureSheetPlaybackMode::Loop
            );
            assert_eq!(settings.start_frame, 3);
            assert_eq!(settings.frame_randomness, 2);
        }
        _ => panic!("expected texture sheet module settings"),
    }

    edit_module(&mut stack, "emission", |settings| {
        if let ParticleEmitterModuleSettings::Emission(module) = settings {
            module.emission_rate = -4.0;
            module.max_particles = -8;
            module.max_spawned_particles_per_frame = -3;
            module.seed = 42;
        }
    });
    edit_module(&mut stack, "collision", |settings| {
        if let ParticleEmitterModuleSettings::Collision(module) = settings {
            module.collision_restitution = 2.0;
            module.collision_damping = -1.0;
        }
    });
    edit_module(&mut stack, "textureSheet", |settings| {
        if let ParticleEmitterModuleSettings::TextureSheet(module) = settings {
            module.texture_asset_id = Some(String::new());
            module.columns = 0;
            module.rows = -2;
            module.frame_count = 0;
            module.playback_mode = ParticleTextureSheetPlaybackMode::SingleFrame;
            module.frame_randomness = -3;
        }
    });
    edit_module(&mut stack, "gpuSimulation", |settings| {
        if let ParticleEmitterModuleSettings::GpuSimulation(module) = settings {
            module.workgroup_size = 0;
        }
    });

    let mut applied = ParticleEmitter::default();
    applied.apply(stack);

    assert_eq!(applied.settings.emission.emission_rate, 0.0);
    assert_eq!(applied.settings.emission.max_particles, 0);
    assert_eq!(applied.settings.emission.max_spawned_particles_per_frame, 0);
    assert_eq!(applied.settings.emission.seed, 42);
    assert_eq!(applied.settings.collision.collision_restitution, 1.0);
    assert_eq!(applied.settings.collision.collision_damping, 0.0);
    assert_eq!(applied.settings.texture_sheet.texture_asset_id, None);
    assert_eq!(applied.settings.texture_sheet.columns, 1);
    assert_eq!(applied.settings.texture_sheet.rows, 1);
    assert_eq!(applied.settings.texture_sheet.frame_count, 1);
    assert_eq!(
        applied.settings.texture_sheet.playback_mode,
        ParticleTextureSheetPlaybackMode::SingleFrame
    );
    assert_eq!(applied.settings.texture_sheet.frame_randomness, 0);
    assert_eq!(applied.settings.gpu_simulation.workgroup_size, 1);
}

/// Module stack preserves disabled authored settings while rebasing enabled
/// modules.
#[test]
fn module_stack_preserves_disabled_authored_settings_while_rebasing_enabled_modules() {
    let mut emitter = emitter_with(|settings| {
        settings.forces.gravity = Float3::new(0.0, -9.81, 0.0);
    });
    let mut stack = emitter.module_stack();
    let forces_index = stack
        .modules
        .iter()
        .position(|module| module.id == "forces")
        .expect("forces module");
    stack.modules[forces_index].is_enabled = false;
    match &mut stack.modules[forces_index].settings {
        ParticleEmitterModuleSettings::Forces(settings) => {
            settings.gravity = Float3::new(4.0, 5.0, 6.0);
        }
        _ => panic!("expected forces module settings"),
    }

    emitter.apply(stack);
    emitter.settings.emission.emission_rate = 24.0;
    emitter.settings.forces.gravity = Float3::new(1.0, 2.0, 3.0);

    let rebased = emitter.module_stack();
    let emission = rebased
        .modules
        .iter()
        .find(|module| module.id == "emission")
        .expect("emission module");
    match &emission.settings {
        ParticleEmitterModuleSettings::Emission(settings) => {
            assert_eq!(settings.emission_rate, 24.0);
        }
        _ => panic!("expected emission module settings"),
    }
    let forces = rebased
        .modules
        .iter()
        .find(|module| module.id == "forces")
        .expect("forces module");
    assert!(!forces.is_enabled);
    match &forces.settings {
        ParticleEmitterModuleSettings::Forces(settings) => {
            assert_eq!(settings.gravity, Float3::new(4.0, 5.0, 6.0));
        }
        _ => panic!("expected forces module settings"),
    }
}

/// Module stack applies seed and reseeds the random stream.
#[test]
fn module_stack_applies_seed_and_reseeds_random_stream() {
    let mut applied = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 1.0;
        settings.shape.spawn_radius = 2.0;
        settings.appearance.size_randomness = 0.5;
        settings.texture_sheet.frame_randomness = 3;
        settings.emission.seed = 1;
    });
    let mut stack = applied.module_stack();
    edit_module(&mut stack, "emission", |settings| {
        if let ParticleEmitterModuleSettings::Emission(module) = settings {
            module.seed = 77;
        }
    });

    let mut expected = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 1.0;
        settings.shape.spawn_radius = 2.0;
        settings.appearance.size_randomness = 0.5;
        settings.texture_sheet.frame_randomness = 3;
        settings.emission.seed = 77;
    });
    applied.apply(stack);
    applied.emit(4, None);
    expected.emit(4, None);

    assert_eq!(applied.settings.emission.seed, 77);
    assert_eq!(applied.particles(), expected.particles());
}

/// Module stack preserves custom order and reset restores default authoring.
#[test]
fn module_stack_preserves_custom_order_and_resets_authoring() {
    let mut emitter = ParticleEmitter::default();
    let mut stack = emitter.module_stack();
    let texture_sheet_index = stack
        .modules
        .iter()
        .position(|module| module.id == "textureSheet")
        .expect("texture sheet module");
    stack.move_module(texture_sheet_index, 0);
    stack.modules[0].is_enabled = false;

    emitter.apply(stack);

    let rebased = emitter.module_stack();
    assert_eq!(
        rebased.modules.first().map(|module| module.id.as_str()),
        Some("textureSheet")
    );
    assert_eq!(
        rebased.modules.first().map(|module| module.is_enabled),
        Some(false)
    );

    let mut reset = emitter.module_stack();
    reset.reset_authoring_state();

    let expected_ids: Vec<String> = ParticleModuleStack::DEFAULT_MODULE_IDS
        .iter()
        .map(|id| id.to_string())
        .collect();
    assert_eq!(module_ids(&reset), expected_ids);
    assert!(reset.modules.iter().all(|module| module.is_enabled));
    assert!(reset.modules.iter().all(|module| !module.is_expanded));
}

/// Module stack validation reports authoring issues before runtime clamping.
#[test]
fn module_stack_validation_reports_authoring_issues() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 8.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 1.0;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuRequired;
    });
    let mut stack = emitter.module_stack();
    edit_module(&mut stack, "emission", |settings| {
        if let ParticleEmitterModuleSettings::Emission(module) = settings {
            module.is_emitting = true;
            module.emission_rate = 0.0;
            module.distance_emission_rate = 0.0;
            module.burst_count = 0;
            module.max_particles = 0;
            module.max_spawned_particles_per_frame = -1;
            module.simulation_speed = -1.0;
        }
    });
    edit_module(&mut stack, "appearance", |settings| {
        if let ParticleEmitterModuleSettings::Appearance(module) = settings {
            module.lifetime = 0.0;
        }
    });
    edit_module(&mut stack, "textureSheet", |settings| {
        if let ParticleEmitterModuleSettings::TextureSheet(module) = settings {
            module.columns = 2;
            module.rows = 2;
            module.frame_count = 8;
        }
    });
    edit_module(&mut stack, "renderer", |settings| {
        if let ParticleEmitterModuleSettings::Renderer(module) = settings {
            module.velocity_stretch_scale = -1.0;
            module.velocity_stretch_max = 0.0;
            module.max_render_distance = 10.0;
            module.render_distance_fade_range = 20.0;
            module.render_lod_start_distance = 30.0;
            module.render_lod_end_distance = 10.0;
            module.render_lod_min_particle_scale = 1.5;
            module.render_bounds_mode = ParticleRenderBoundsMode::Manual;
            module.render_bounds_radius = -1.0;
        }
    });
    edit_module(&mut stack, "trails", |settings| {
        if let ParticleEmitterModuleSettings::Trails(module) = settings {
            module.trail_length = -1.0;
            module.trail_segments = -2;
            module.ribbon_smoothing_segments = 0;
            module.ribbon_tail_alpha_scale = 2.0;
            module.ribbon_width_scale = -1.0;
            module.ribbon_max_segment_length = -4.0;
            module.ribbon_texture_tiling = -1.0;
            module.trail_end_size_scale = -0.5;
            module.trail_end_alpha_scale = -0.25;
        }
    });
    edit_module(&mut stack, "gpuSimulation", |settings| {
        if let ParticleEmitterModuleSettings::GpuSimulation(module) = settings {
            module.workgroup_size = ParticleGPUSimulationPlan::MAXIMUM_WORKGROUP_SIZE + 1;
        }
    });

    let stack_issue_codes = issue_codes(&stack);

    assert!(has_code(&stack_issue_codes, "noParticleCapacity"));
    assert!(has_code(&stack_issue_codes, "negativeSpawnBudget"));
    assert!(has_code(&stack_issue_codes, "noSpawnSource"));
    assert!(has_code(&stack_issue_codes, "negativeSimulationSpeed"));
    assert!(has_code(&stack_issue_codes, "invalidLifetime"));
    assert!(has_code(&stack_issue_codes, "frameCountExceedsCells"));
    assert!(has_code(&stack_issue_codes, "negativeVelocityStretch"));
    assert!(has_code(&stack_issue_codes, "fadeRangeExceedsDistance"));
    assert!(has_code(&stack_issue_codes, "invalidLODRange"));
    assert!(has_code(&stack_issue_codes, "lodScaleOutOfRange"));
    assert!(has_code(&stack_issue_codes, "negativeRenderBoundsRadius"));
    assert!(has_code(&stack_issue_codes, "negativeTrailSettings"));
    assert!(has_code(&stack_issue_codes, "invalidRibbonSmoothing"));
    assert!(has_code(&stack_issue_codes, "tailAlphaOutOfRange"));
    assert!(has_code(&stack_issue_codes, "negativeRibbonWidth"));
    assert!(has_code(&stack_issue_codes, "negativeRibbonSegment"));
    assert!(has_code(&stack_issue_codes, "negativeRibbonTiling"));
    assert!(has_code(&stack_issue_codes, "negativeTrailEndSize"));
    assert!(has_code(&stack_issue_codes, "trailEndAlphaOutOfRange"));
    assert!(has_code(&stack_issue_codes, "gpuWorkgroupClamped"));

    emitter.apply(stack.clone());
    let emitter_issues = emitter.module_validation_issues();
    assert!(emitter_issues.iter().any(|issue| {
        issue.module_id == "gpuSimulation" && issue.code == "gpuRequiredButUnsupported"
    }));

    stack.repair_validation_issues();
    let repaired_issue_codes = issue_codes(&stack);

    assert!(!has_code(&repaired_issue_codes, "noParticleCapacity"));
    assert!(!has_code(&repaired_issue_codes, "negativeSpawnBudget"));
    assert!(!has_code(&repaired_issue_codes, "negativeSimulationSpeed"));
    assert!(has_code(&repaired_issue_codes, "noSpawnSource"));
    assert!(!has_code(&repaired_issue_codes, "invalidLifetime"));
    assert!(!has_code(&repaired_issue_codes, "frameCountExceedsCells"));
    assert!(!has_code(&repaired_issue_codes, "negativeVelocityStretch"));
    assert!(!has_code(&repaired_issue_codes, "fadeRangeExceedsDistance"));
    assert!(!has_code(&repaired_issue_codes, "invalidLODRange"));
    assert!(!has_code(&repaired_issue_codes, "lodScaleOutOfRange"));
    assert!(!has_code(
        &repaired_issue_codes,
        "negativeRenderBoundsRadius"
    ));
    assert!(!has_code(&repaired_issue_codes, "negativeTrailSettings"));
    assert!(!has_code(&repaired_issue_codes, "invalidRibbonSmoothing"));
    assert!(!has_code(&repaired_issue_codes, "tailAlphaOutOfRange"));
    assert!(!has_code(&repaired_issue_codes, "negativeRibbonWidth"));
    assert!(!has_code(&repaired_issue_codes, "negativeRibbonSegment"));
    assert!(!has_code(&repaired_issue_codes, "negativeRibbonTiling"));
    assert!(!has_code(&repaired_issue_codes, "negativeTrailEndSize"));
    assert!(!has_code(&repaired_issue_codes, "trailEndAlphaOutOfRange"));
    assert!(!has_code(&repaired_issue_codes, "gpuWorkgroupClamped"));

    emitter.apply(stack);
    assert!(!emitter.module_validation_issues().iter().any(|issue| {
        issue.module_id == "gpuSimulation" && issue.code == "gpuRequiredButUnsupported"
    }));
}

/// Module stack repair removes duplicate modules and restores missing defaults.
#[test]
fn module_stack_repair_normalizes_topology() {
    let mut stack = ParticleEmitter::default().module_stack();
    let emission = stack.modules[0].clone();
    stack.modules[0].display_name = "Legacy Emission".to_string();
    stack.modules[0].stage = ParticleModuleStage::Render;
    stack.modules[0].is_enabled = false;
    stack.modules.insert(1, emission);
    stack.modules.retain(|module| module.id != "trails");

    let codes = issue_codes(&stack);
    assert!(has_code(&codes, "duplicateModule"));
    assert!(has_code(&codes, "missingModule"));

    stack.repair_validation_issues();

    let repaired_codes = issue_codes(&stack);
    assert!(!has_code(&repaired_codes, "duplicateModule"));
    assert!(!has_code(&repaired_codes, "missingModule"));
    assert_eq!(stack.version, ParticleModuleStack::CURRENT_VERSION);
    assert_eq!(
        stack
            .modules
            .iter()
            .filter(|module| module.id == "emission")
            .count(),
        1
    );
    assert_eq!(
        stack
            .modules
            .iter()
            .filter(|module| module.id == "trails")
            .count(),
        1
    );
    for default_id in ParticleModuleStack::DEFAULT_MODULE_IDS {
        assert!(
            stack.modules.iter().any(|module| module.id == default_id),
            "missing default module '{default_id}'"
        );
    }

    let repaired_emission = stack
        .modules
        .iter()
        .find(|module| module.id == "emission")
        .expect("emission module");
    assert_eq!(repaired_emission.display_name, "Emission");
    assert_eq!(repaired_emission.stage, ParticleModuleStage::Spawn);
    assert!(!repaired_emission.is_enabled);

    let repaired_trails = stack
        .modules
        .iter()
        .find(|module| module.id == "trails")
        .expect("trails module");
    assert_eq!(repaired_trails.display_name, "Trails");
    assert!(repaired_trails.is_enabled);
}

/// Module stack can repair a single authored module.
#[test]
fn module_stack_repairs_single_module() {
    let mut stack = ParticleEmitter::default().module_stack();
    edit_module(&mut stack, "emission", |settings| {
        if let ParticleEmitterModuleSettings::Emission(module) = settings {
            module.max_particles = 0;
            module.simulation_speed = -1.0;
        }
    });
    edit_module(&mut stack, "renderer", |settings| {
        if let ParticleEmitterModuleSettings::Renderer(module) = settings {
            module.velocity_stretch_scale = -1.0;
            module.render_lod_start_distance = 20.0;
            module.render_lod_end_distance = 10.0;
        }
    });

    stack.repair_validation_issues_for("renderer");
    let codes = issue_codes(&stack);

    assert!(has_code(&codes, "noParticleCapacity"));
    assert!(has_code(&codes, "negativeSimulationSpeed"));
    assert!(!has_code(&codes, "negativeVelocityStretch"));
    assert!(!has_code(&codes, "invalidLODRange"));
}

/// Module stack can reset a single module to default settings.
#[test]
fn module_stack_resets_single_module_settings() {
    let mut stack = ParticleEmitter::default().module_stack();
    let renderer_index = stack
        .modules
        .iter()
        .position(|module| module.id == "renderer")
        .expect("renderer module");
    stack.modules[renderer_index].is_enabled = false;
    stack.modules[renderer_index].is_expanded = true;
    match &mut stack.modules[renderer_index].settings {
        ParticleEmitterModuleSettings::Renderer(module) => {
            module.render_mode = ParticleRenderMode::Ribbon;
            module.render_sort_priority = 42;
            module.render_bounds_mode = ParticleRenderBoundsMode::Manual;
            module.render_bounds_radius = 99.0;
        }
        _ => panic!("expected renderer module settings"),
    }

    assert!(stack.module_settings_differ_from_default("renderer"));
    stack.reset_module_settings("renderer");

    let reset_renderer = stack
        .modules
        .iter()
        .find(|module| module.id == "renderer")
        .expect("renderer module");
    let default_stack = ParticleModuleStack::from_emitter(&ParticleEmitter::default());
    let default_renderer = default_stack
        .modules
        .iter()
        .find(|module| module.id == "renderer")
        .expect("default renderer module");
    assert!(!reset_renderer.is_enabled);
    assert!(reset_renderer.is_expanded);
    assert_eq!(reset_renderer.stage, default_renderer.stage);
    assert_eq!(reset_renderer.display_name, default_renderer.display_name);
    assert_eq!(reset_renderer.settings, default_renderer.settings);
    assert!(!stack.module_settings_differ_from_default("renderer"));
}

/// Module stack reports modules modified from defaults.
#[test]
fn module_stack_reports_modified_modules() {
    let mut stack = ParticleEmitter::default().module_stack();
    assert!(stack.modified_module_ids().is_empty());

    edit_module(&mut stack, "emission", |settings| {
        if let ParticleEmitterModuleSettings::Emission(module) = settings {
            module.emission_rate = 123.0;
        }
    });
    edit_module(&mut stack, "renderer", |settings| {
        if let ParticleEmitterModuleSettings::Renderer(module) = settings {
            module.render_sort_priority = 5;
        }
    });

    assert_eq!(stack.modified_module_ids(), vec!["emission", "renderer"]);
    stack.reset_module_settings("emission");
    assert_eq!(stack.modified_module_ids(), vec!["renderer"]);
    stack.reset_module_settings("renderer");
    assert!(stack.modified_module_ids().is_empty());
}

/// Module modified state ignores enabled and expansion authoring flags.
#[test]
fn module_modified_state_ignores_enabled_and_expansion_flags() {
    let mut stack = ParticleEmitter::default().module_stack();
    let renderer_index = stack
        .modules
        .iter()
        .position(|module| module.id == "renderer")
        .expect("renderer module");

    stack.modules[renderer_index].is_enabled = false;
    stack.modules[renderer_index].is_expanded = true;

    assert!(!stack.module_settings_differ_from_default("renderer"));
    assert!(stack.modified_module_ids().is_empty());
}

/// Module stack can focus modified and invalid modules.
#[test]
fn module_stack_can_focus_modified_and_invalid_modules() {
    let mut stack = ParticleEmitter::default().module_stack();
    edit_module(&mut stack, "emission", |settings| {
        if let ParticleEmitterModuleSettings::Emission(module) = settings {
            module.emission_rate = 123.0;
        }
    });
    edit_module(&mut stack, "renderer", |settings| {
        if let ParticleEmitterModuleSettings::Renderer(module) = settings {
            module.render_lod_start_distance = 40.0;
            module.render_lod_end_distance = 10.0;
        }
    });

    stack.expand_modified_modules(true);
    assert_eq!(stack.expanded_module_ids(), vec!["emission", "renderer"]);

    stack.collapse_all_modules();
    assert!(stack.expanded_module_ids().is_empty());

    let focused_issue_ids = stack.expand_modules_with_validation_issues(true);
    assert_eq!(focused_issue_ids, vec!["renderer"]);
    assert_eq!(stack.expanded_module_ids(), vec!["renderer"]);
}

/// Continuous emission spawns at the configured rate.
#[test]
fn continuous_emission() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 1000;
        settings.appearance.lifetime = 1000.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    for _ in 0..10 {
        advance(&mut emitter, 0.1);
    }
    assert_eq!(emitter.alive_count(), 10);
}

/// Simulation speed scales particle aging and emission.
#[test]
fn simulation_speed_scales_aging_and_emission() {
    let mut slow = emitter_with(|settings| {
        settings.emission.simulation_speed = 0.5;
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 100.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    advance(&mut slow, 1.0);
    assert_eq!(slow.alive_count(), 5);
    assert_eq!(slow.last_frame_stats().simulated_delta_time, 0.5);

    let mut fast = emitter_with(|settings| {
        settings.emission.simulation_speed = 2.0;
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 100.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    advance(&mut fast, 1.0);
    assert_eq!(fast.alive_count(), 20);
    assert_eq!(fast.last_frame_stats().simulated_delta_time, 2.0);
}

/// Zero simulation speed pauses particle aging and distance emission.
#[test]
fn zero_simulation_speed_pauses_particles() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.simulation_speed = 0.0;
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::new(1.0, 0.0, 0.0);
        settings.forces.gravity = Float3::ZERO;
    });
    emitter.emit(1, None);
    let start = translated(0.0, 0.0, 0.0);
    advance_within(&mut emitter, 1.0, start);

    let moved = translated(5.0, 0.0, 0.0);
    advance_within(&mut emitter, 1.0, moved);

    assert_eq!(emitter.alive_count(), 1);
    assert_eq!(emitter.particles()[0].age, 0.0);
    assert_eq!(emitter.particles()[0].position, Float3::ZERO);
    assert_eq!(emitter.last_frame_stats().simulated_delta_time, 0.0);
    assert_eq!(emitter.last_frame_stats().distance_spawned_count, 0);
}

/// Frame spawned particles track accepted advance emissions.
#[test]
fn frame_spawned_particles_track_accepted_advance_emissions() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 1;
        settings.appearance.lifetime = 100.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });

    advance(&mut emitter, 0.2);

    assert_eq!(emitter.alive_count(), 1);
    assert_eq!(emitter.last_frame_stats().continuous_spawned_count, 1);
    assert_eq!(emitter.last_frame_stats().capacity_limited_spawn_count, 1);
    assert_eq!(emitter.last_frame_spawned_particles().len(), 1);

    emitter.settings.emission.is_emitting = false;
    advance(&mut emitter, 0.1);

    assert_eq!(emitter.alive_count(), 1);
    assert_eq!(emitter.last_frame_stats().spawned_particle_count(), 0);
    assert!(emitter.last_frame_spawned_particles().is_empty());
}

/// Per-frame spawn budget throttles continuous emission.
#[test]
fn per_frame_spawn_budget_throttles_continuous_emission() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 100.0;
        settings.emission.max_particles = 100;
        settings.emission.max_spawned_particles_per_frame = 3;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });

    advance(&mut emitter, 0.1);

    assert_eq!(emitter.alive_count(), 3);
    assert_eq!(emitter.last_frame_stats().requested_spawn_count, 10);
    assert_eq!(emitter.last_frame_stats().continuous_spawned_count, 3);
    assert_eq!(emitter.last_frame_stats().spawn_budget_limit, 3);
    assert_eq!(emitter.last_frame_stats().spawn_budget_consumed_count, 3);
    assert!((emitter.last_frame_stats().spawn_budget_utilization() - 1.0).abs() < 0.0001);
    assert_eq!(emitter.last_frame_stats().capacity_limited_spawn_count, 0);
    assert_eq!(emitter.last_frame_stats().spawn_budget_limited_count, 7);
    assert_eq!(emitter.last_frame_stats().dropped_spawn_count(), 7);

    advance(&mut emitter, 0.1);

    assert_eq!(emitter.alive_count(), 6);
    assert_eq!(emitter.last_frame_stats().continuous_spawned_count, 3);
    assert_eq!(emitter.last_frame_stats().spawn_budget_limited_count, 7);
}

/// Per-frame spawn budget throttles event sub-emitters.
#[test]
fn per_frame_spawn_budget_throttles_event_sub_emitters() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 100.0;
        settings.emission.max_particles = 100;
        settings.emission.max_spawned_particles_per_frame = 2;
        settings.appearance.lifetime = 0.1;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Death;
        settings.sub_emitters.legacy_burst_count = 4;
        settings.sub_emitters.legacy_max_depth = 1;
        settings.sub_emitters.legacy_lifetime = 1.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 0.2);

    assert_eq!(emitter.alive_count(), 2);
    assert_eq!(emitter.last_frame_stats().requested_spawn_count, 4);
    assert_eq!(emitter.last_frame_stats().sub_emitter_spawned_count, 2);
    assert_eq!(emitter.last_frame_stats().distance_spawned_count, 0);
    assert_eq!(emitter.last_frame_stats().spawn_budget_limit, 2);
    assert_eq!(emitter.last_frame_stats().spawn_budget_consumed_count, 2);
    assert_eq!(emitter.last_frame_stats().spawn_budget_limited_count, 2);
    assert_eq!(emitter.last_frame_stats().capacity_limited_spawn_count, 0);
}

/// Scheduled bursts spawn particles at configured intervals.
#[test]
fn scheduled_bursts() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.burst_count = 3;
        settings.emission.burst_interval = 0.5;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 100.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    advance(&mut emitter, 0.49);
    assert_eq!(emitter.alive_count(), 0);
    advance(&mut emitter, 0.01);
    assert_eq!(emitter.alive_count(), 3);
    advance(&mut emitter, 1.0);
    assert_eq!(emitter.alive_count(), 9);
}

/// Distance emission spawns particles after the emitter moves.
#[test]
fn distance_emission() {
    let start = translated(0.0, 0.0, 0.0);
    let moved = translated(1.0, 0.0, 0.0);
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 4.0;
        settings.emission.max_particles = 16;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });

    advance_within(&mut emitter, 0.1, start);
    assert_eq!(emitter.alive_count(), 0);

    advance_within(&mut emitter, 0.1, moved);
    assert_eq!(emitter.alive_count(), 4);
    let positions: Vec<f32> = emitter
        .particles()
        .iter()
        .map(|particle| particle.position.x)
        .collect();
    assert_eq!(positions, vec![0.125, 0.375, 0.625, 0.875]);
}

/// Distance emission carries fractional movement between frames.
#[test]
fn distance_emission_accumulator() {
    let mut start = MATRIX_IDENTITY_FLOAT4X4;
    let mut moved = MATRIX_IDENTITY_FLOAT4X4;
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 2.0;
        settings.emission.max_particles = 16;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });

    advance_within(&mut emitter, 0.1, start);
    moved.columns[3] = Float4::new(0.25, 0.0, 0.0, 1.0);
    advance_within(&mut emitter, 0.1, moved);
    assert_eq!(emitter.alive_count(), 0);

    start.columns[3] = Float4::new(0.5, 0.0, 0.0, 1.0);
    advance_within(&mut emitter, 0.1, start);
    assert_eq!(emitter.alive_count(), 1);
}

/// Per-frame spawn budget caps distance emission.
#[test]
fn per_frame_spawn_budget_caps_distance_emission() {
    let start = MATRIX_IDENTITY_FLOAT4X4;
    let moved = translated(1.0, 0.0, 0.0);
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.emission.max_spawned_particles_per_frame = 3;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });

    advance_within(&mut emitter, 0.1, start);
    advance_within(&mut emitter, 0.1, moved);

    assert_eq!(emitter.alive_count(), 3);
    assert_eq!(emitter.last_frame_stats().requested_spawn_count, 10);
    assert_eq!(emitter.last_frame_stats().distance_spawned_count, 3);
    assert_eq!(emitter.last_frame_stats().spawn_budget_limit, 3);
    assert_eq!(emitter.last_frame_stats().spawn_budget_consumed_count, 3);
    assert_eq!(emitter.last_frame_stats().spawn_budget_limited_count, 7);
    assert!((emitter.particles()[0].position.x - 0.16666667).abs() < 0.0001);
    assert!((emitter.particles()[1].position.x - 0.5).abs() < 0.0001);
    assert!((emitter.particles()[2].position.x - 0.8333334).abs() < 0.0001);
}

/// Spawned particles can inherit emitter velocity.
#[test]
fn velocity_inheritance() {
    let start = MATRIX_IDENTITY_FLOAT4X4;
    let moved = translated(2.0, 0.0, 0.0);
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 1.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.velocity.velocity_inheritance = 0.5;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });

    advance_within(&mut emitter, 1.0, start);
    advance_within(&mut emitter, 1.0, moved);

    assert_eq!(emitter.alive_count(), 2);
    assert!(
        emitter
            .particles()
            .iter()
            .all(|particle| particle.velocity == Float3::new(1.0, 0.0, 0.0))
    );
}

/// Non-looping duration stops new emissions.
#[test]
fn non_looping_duration_stops_emission() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.looping = false;
        settings.emission.duration = 0.5;
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 100.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    advance(&mut emitter, 0.5);
    assert_eq!(emitter.alive_count(), 5);
    advance(&mut emitter, 1.0);
    assert_eq!(emitter.alive_count(), 5);

    emitter.clear();
    advance(&mut emitter, 0.1);
    assert_eq!(emitter.alive_count(), 1);
}

/// Non-looping emitter reports inactive once duration is exhausted.
#[test]
fn non_looping_emitter_reports_inactive_after_duration() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.looping = false;
        settings.emission.duration = 0.25;
        settings.emission.emission_rate = 4.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 0.1;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });

    assert!(emitter.is_emission_active());
    advance(&mut emitter, 0.25);
    assert!(!emitter.is_emission_active());
    assert_eq!(emitter.alive_count(), 1);

    advance(&mut emitter, 0.2);
    assert!(!emitter.is_emission_active());
    assert_eq!(emitter.alive_count(), 0);

    emitter.clear();
    assert!(emitter.is_emission_active());
}

/// Looping emitter remains active after duration wraps.
#[test]
fn looping_emitter_remains_active_after_duration_wraps() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.looping = true;
        settings.emission.duration = 0.25;
        settings.emission.emission_rate = 0.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });

    advance(&mut emitter, 2.0);

    assert!(emitter.is_emission_active());
}

/// Particles are culled once they exceed their lifetime.
#[test]
fn lifetime_culling() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 0.5;
        settings.forces.gravity = Float3::ZERO;
    });
    emitter.emit(3, None);
    assert_eq!(emitter.alive_count(), 3);
    // age 0.6 > lifetime 0.5
    advance(&mut emitter, 0.6);
    assert_eq!(emitter.alive_count(), 0);
}

/// Swift's memberwise `ParticleSubEmitter(…)` with the defaulted arguments
/// supplied by `ParticleSubEmitter`'s `Default`.
fn sub_emitter(configure: impl FnOnce(&mut ParticleSubEmitter)) -> ParticleSubEmitter {
    let mut rule = ParticleSubEmitter::default();
    configure(&mut rule);
    rule
}

/// Death events spawn child particles with their own appearance.
#[test]
fn death_sub_emitter() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 0.5;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Death;
        settings.sub_emitters.legacy_burst_count = 2;
        settings.sub_emitters.legacy_max_depth = 1;
        settings.sub_emitters.legacy_lifetime = 2.0;
        settings.sub_emitters.legacy_start_velocity = Float3::new(1.0, 0.0, 0.0);
        settings.sub_emitters.legacy_velocity_randomness = Float3::ZERO;
        settings.sub_emitters.legacy_start_size = 0.25;
        settings.sub_emitters.legacy_end_size = 0.25;
        settings.sub_emitters.legacy_start_color = Float4::new(1.0, 0.0, 0.0, 1.0);
        settings.sub_emitters.legacy_end_color = Float4::new(1.0, 0.0, 0.0, 1.0);
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 0.6);

    assert_eq!(emitter.alive_count(), 2);
    let events = emitter.last_frame_events().to_vec();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].trigger, ParticleSubEmitterTrigger::Death);
    assert_eq!(events[0].generation, 0);
    assert!(events[0].age >= 0.6);
    assert_eq!(events[0].lifetime, 0.5);
    for child in emitter.particles() {
        assert_eq!(child.generation, 1);
        assert_eq!(child.lifetime, 2.0);
        assert_eq!(child.velocity, Float3::new(1.0, 0.0, 0.0));
        assert_eq!(child.size, 0.25);
        assert_eq!(child.color, Float4::new(1.0, 0.0, 0.0, 1.0));
    }

    advance(&mut emitter, 2.1);
    assert_eq!(emitter.alive_count(), 0);
    assert_eq!(emitter.last_frame_events().len(), 2);

    emitter.clear();
    assert!(emitter.last_frame_events().is_empty());
}

/// Each death rule spawns its own children with an independent appearance.
#[test]
fn multiple_death_sub_emitters() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 0.5;
        settings.sub_emitters.rules = vec![
            sub_emitter(|rule| {
                rule.trigger = ParticleSubEmitterTrigger::Death;
                rule.burst_count = 1;
                rule.lifetime = 2.0;
                rule.start_velocity = Float3::new(1.0, 0.0, 0.0);
                rule.start_size = 0.2;
                rule.end_size = 0.2;
                rule.start_color = Float4::new(1.0, 0.0, 0.0, 1.0);
                rule.end_color = Float4::new(1.0, 0.0, 0.0, 1.0);
            }),
            sub_emitter(|rule| {
                rule.trigger = ParticleSubEmitterTrigger::Death;
                rule.burst_count = 2;
                rule.lifetime = 3.0;
                rule.start_velocity = Float3::new(0.0, 1.0, 0.0);
                rule.start_size = 0.4;
                rule.end_size = 0.4;
                rule.start_color = Float4::new(0.0, 0.0, 1.0, 1.0);
                rule.end_color = Float4::new(0.0, 0.0, 1.0, 1.0);
            }),
        ];
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 0.6);

    assert_eq!(emitter.alive_count(), 3);
    let red_children: Vec<&Particle> = emitter
        .particles()
        .iter()
        .filter(|particle| particle.appearance_index == 2)
        .collect();
    let blue_children: Vec<&Particle> = emitter
        .particles()
        .iter()
        .filter(|particle| particle.appearance_index == 3)
        .collect();
    assert_eq!(red_children.len(), 1);
    assert_eq!(blue_children.len(), 2);
    assert!(
        red_children
            .iter()
            .all(|particle| particle.generation == 1 && particle.lifetime == 2.0)
    );
    assert!(
        red_children
            .iter()
            .all(|particle| particle.velocity == Float3::new(1.0, 0.0, 0.0))
    );
    assert!(
        red_children
            .iter()
            .all(|particle| particle.size == 0.2
                && particle.color == Float4::new(1.0, 0.0, 0.0, 1.0))
    );
    assert!(
        blue_children
            .iter()
            .all(|particle| particle.generation == 1 && particle.lifetime == 3.0)
    );
    assert!(
        blue_children
            .iter()
            .all(|particle| particle.velocity == Float3::new(0.0, 1.0, 0.0))
    );
    assert!(
        blue_children
            .iter()
            .all(|particle| particle.size == 0.4
                && particle.color == Float4::new(0.0, 0.0, 1.0, 1.0))
    );
}

/// Collision events spawn children at the point of contact.
#[test]
fn collision_sub_emitter() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 10.0;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Collision;
        settings.sub_emitters.legacy_burst_count = 1;
        settings.sub_emitters.legacy_lifetime = 2.0;
        settings.sub_emitters.legacy_start_velocity = Float3::new(2.0, 0.0, 0.0);
        settings.sub_emitters.legacy_velocity_randomness = Float3::ZERO;
        settings.shape.origin_offset = Float3::new(0.0, 0.5, 0.0);
        settings.velocity.start_velocity = Float3::new(0.0, -1.0, 0.0);
        settings.forces.gravity = Float3::ZERO;
        settings.collision.collision_mode = ParticleCollisionMode::LocalPlane;
        settings.collision.collision_plane_y = 0.0;
        settings.collision.collision_restitution = 0.5;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 1.0);

    assert_eq!(emitter.alive_count(), 2);
    let parent = particle_with_generation(&emitter, 0).expect("parent particle");
    let child = particle_with_generation(&emitter, 1).expect("child particle");
    assert_eq!(parent.position.y, 0.0);
    assert!((parent.velocity.y - 0.5).abs() < 1e-4);
    assert_eq!(child.position.y, 0.0);
    assert_eq!(child.velocity, Float3::new(2.0, 0.0, 0.0));
    let events = emitter.last_frame_events().to_vec();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].trigger, ParticleSubEmitterTrigger::Collision);
    assert_eq!(events[0].position.y, 0.0);
    assert!((events[0].velocity.y - 0.5).abs() < 1e-4);
}

/// External simulation events drive sub-emitter spawning without a CPU advance.
#[test]
fn external_simulation_events_drive_sub_emitters() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 10.0;
        settings.sub_emitters.rules = vec![sub_emitter(|rule| {
            rule.trigger = ParticleSubEmitterTrigger::Death;
            rule.burst_count = 2;
            rule.max_depth = 2;
            rule.inherit_velocity = 0.5;
            rule.lifetime = 3.0;
            rule.start_velocity = Float3::new(1.0, 0.0, 0.0);
            rule.velocity_randomness = Float3::ZERO;
            rule.start_size = 0.3;
            rule.end_size = 0.1;
            rule.start_color = Float4::new(1.0, 0.0, 0.0, 1.0);
            rule.end_color = Float4::new(1.0, 1.0, 0.0, 0.5);
        })];
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    let source_event = ParticleEvent::new(
        ParticleSubEmitterTrigger::Death,
        Float3::new(2.0, 3.0, 4.0),
        Float3::new(0.0, 2.0, 0.0),
        0.75,
        1.5,
        0,
        0,
    );

    let stats = emitter.apply_simulation_events(&[source_event]);

    assert_eq!(stats.expired_particle_count, 1);
    assert_eq!(stats.sub_emitter_spawned_count, 2);
    assert_eq!(stats.spawned_particle_count(), 2);
    assert_eq!(stats.live_particle_count, 2);
    assert_eq!(emitter.last_frame_events(), &[source_event]);
    assert_eq!(emitter.last_frame_spawned_particles().len(), 2);
    assert_eq!(emitter.particles().len(), 2);
    for child in emitter.particles() {
        assert_eq!(child.position, Float3::new(2.0, 3.0, 4.0));
        assert_eq!(child.velocity, Float3::new(1.0, 1.0, 0.0));
        assert_eq!(child.generation, 1);
        assert_eq!(child.appearance_index, 2);
        assert_eq!(child.lifetime, 3.0);
        assert_eq!(child.size, 0.3);
        assert_eq!(child.color, Float4::new(1.0, 0.0, 0.0, 1.0));
    }
}

/// The external event bridge clears the previous frame's output.
#[test]
fn external_simulation_event_bridge_clears_stale_output() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 4;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Collision;
        settings.sub_emitters.legacy_burst_count = 1;
        settings.sub_emitters.legacy_lifetime = 1.0;
        settings.sub_emitters.legacy_start_velocity = Float3::new(0.0, 1.0, 0.0);
        settings.sub_emitters.legacy_velocity_randomness = Float3::ZERO;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });
    let source_event = ParticleEvent::new(
        ParticleSubEmitterTrigger::Collision,
        Float3::ZERO,
        Float3::ZERO,
        0.0,
        1.0,
        0,
        0,
    );

    let _ = emitter.apply_simulation_events(&[source_event]);
    assert_eq!(emitter.last_frame_events().len(), 1);
    assert_eq!(emitter.last_frame_spawned_particles().len(), 1);

    let empty_stats = emitter.apply_simulation_events(&[]);

    assert_eq!(empty_stats.spawned_particle_count(), 0);
    assert_eq!(empty_stats.live_particle_count, 1);
    assert!(emitter.last_frame_events().is_empty());
    assert!(emitter.last_frame_spawned_particles().is_empty());
}

/// GPU event sub-emitters wait for external simulation feedback before spawning.
#[test]
fn gpu_event_sub_emitters_defer_to_external_simulation_events() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 8;
        settings.appearance.lifetime = 0.5;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Death;
        settings.sub_emitters.legacy_burst_count = 2;
        settings.sub_emitters.legacy_max_depth = 1;
        settings.sub_emitters.legacy_lifetime = 2.0;
        settings.sub_emitters.legacy_start_velocity = Float3::new(1.0, 0.0, 0.0);
        settings.sub_emitters.legacy_velocity_randomness = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
    });
    assert!(emitter.gpu_simulation_plan().uses_gpu());

    emitter.emit(1, None);
    advance(&mut emitter, 1.0);

    assert_eq!(emitter.alive_count(), 0);
    let stats = emitter.last_frame_stats();
    assert_eq!(stats.expired_particle_count, 1);
    assert_eq!(stats.sub_emitter_spawned_count, 0);
    assert!(emitter.last_frame_events().is_empty());
    assert!(emitter.last_frame_spawned_particles().is_empty());

    let feedback = ParticleEvent::new(
        ParticleSubEmitterTrigger::Death,
        Float3::new(2.0, 0.0, 0.0),
        Float3::ZERO,
        0.5,
        0.5,
        0,
        0,
    );
    let feedback_stats = emitter.apply_simulation_events(&[feedback]);

    assert_eq!(feedback_stats.expired_particle_count, 1);
    assert_eq!(feedback_stats.sub_emitter_spawned_count, 2);
    assert_eq!(emitter.alive_count(), 2);
    assert_eq!(emitter.last_frame_events(), &[feedback]);
    assert_eq!(emitter.last_frame_spawned_particles().len(), 2);
}

/// The CPU backend keeps spawning event sub-emitters itself.
#[test]
fn cpu_backend_keeps_cpu_owned_event_sub_emitter_spawning() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 1.0;
        settings.emission.max_particles = 4;
        settings.appearance.lifetime = 0.5;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Death;
        settings.sub_emitters.legacy_burst_count = 1;
        settings.sub_emitters.legacy_max_depth = 1;
        settings.sub_emitters.legacy_lifetime = 2.0;
        settings.sub_emitters.legacy_start_velocity = Float3::ZERO;
        settings.sub_emitters.legacy_velocity_randomness = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::Cpu;
    });
    let plan = emitter.gpu_simulation_plan();
    assert_eq!(plan.status, ParticleGPUSimulationPlanStatus::Disabled);
    assert!(!plan.uses_gpu());

    emitter.emit(1, None);
    advance(&mut emitter, 1.0);

    assert_eq!(emitter.alive_count(), 1);
    let stats = emitter.last_frame_stats();
    assert_eq!(stats.expired_particle_count, 1);
    assert_eq!(stats.sub_emitter_spawned_count, 1);
    assert_eq!(emitter.last_frame_events().len(), 1);
    assert_eq!(emitter.last_frame_spawned_particles().len(), 1);
}

/// `SceneRuntime` applies external events per entity and reports what it skipped.
#[test]
fn scene_runtime_applies_external_particle_simulation_events_by_entity() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.is_emitting = false;
            settings.emission.emission_rate = 0.0;
            settings.emission.max_particles = 1;
            settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Death;
            settings.sub_emitters.legacy_burst_count = 2;
            settings.sub_emitters.legacy_lifetime = 2.0;
            settings.sub_emitters.legacy_start_velocity = Float3::ZERO;
            settings.sub_emitters.legacy_velocity_randomness = Float3::ZERO;
            settings.forces.gravity = Float3::ZERO;
        }),
        entity,
    );
    let empty = scene.create_entity();
    let missing = EntityID::new(99, 1);
    let event = ParticleEvent::new(
        ParticleSubEmitterTrigger::Death,
        Float3::new(1.0, 2.0, 3.0),
        Float3::ZERO,
        1.0,
        1.0,
        0,
        0,
    );
    let collision = ParticleEvent::new(
        ParticleSubEmitterTrigger::Collision,
        Float3::new(4.0, 5.0, 6.0),
        Float3::new(0.0, 1.0, 0.0),
        0.25,
        1.0,
        0,
        0,
    );

    let report = scene.apply_particle_simulation_events(&BTreeMap::from([
        (entity, vec![event, collision]),
        (empty, Vec::new()),
        (missing, vec![event]),
    ]));

    assert_eq!(report.requested_emitter_count, 3);
    assert_eq!(report.applied_emitter_count, 1);
    assert_eq!(report.missing_emitter_count, 1);
    assert_eq!(report.empty_event_emitter_count, 1);
    assert_eq!(report.event_count, 3);
    assert_eq!(report.applied_event_count, 2);
    assert_eq!(report.death_event_count, 1);
    assert_eq!(report.collision_event_count, 1);
    assert_eq!(report.sub_emitter_spawned_count, 1);
    assert_eq!(report.spawned_particle_count, 1);
    assert_eq!(report.requested_spawn_count, 2);
    assert_eq!(report.spawn_budget_limit, 0);
    assert_eq!(report.spawn_budget_consumed_count, 2);
    assert_eq!(report.capacity_limited_spawn_count, 1);
    assert_eq!(report.dropped_spawn_count(), 1);
    let emitter = scene
        .component::<ParticleEmitter>(entity)
        .expect("particle emitter");
    assert_eq!(emitter.particles().len(), 1);
    assert_eq!(emitter.last_frame_events(), &[event, collision]);
    let frame_stats = scene.particle_frame_stats();
    assert_eq!(frame_stats.sub_emitter_spawned_count, 1);
    assert_eq!(frame_stats.requested_spawn_count, 2);
    assert_eq!(frame_stats.spawn_budget_consumed_count, 2);
    assert_eq!(frame_stats.capacity_limited_spawn_count, 1);
    let entity_stats = report
        .emitter_stats_for(Some(entity.raw_value()))
        .expect("entity stats");
    assert_eq!(entity_stats.sub_emitter_spawned_count, 1);
    assert_eq!(entity_stats.requested_spawn_count, 2);
    assert_eq!(entity_stats.capacity_limited_spawn_count, 1);
    let stored_stats = frame_stats
        .emitter_stats_for(Some(entity.raw_value()))
        .expect("stored entity stats");
    assert_eq!(stored_stats.sub_emitter_spawned_count, 1);
    assert!(
        frame_stats
            .emitter_stats_for(Some(missing.raw_value()))
            .is_none()
    );
}

/// GPU readback stats merge into the frame stats without replacing CPU stats.
#[test]
fn scene_runtime_merges_gpu_particle_readback_stats_into_frame_stats() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.emission_rate = 2.0;
            settings.emission.max_particles = 8;
        }),
        entity,
    );
    let _ = scene.tick(1.0, 0, Vec::new());

    let mut report = ParticleSimulationEventApplyReport::empty();
    report.gpu_alive_particle_count = 7;
    report.gpu_expired_particle_count = 1;
    report.gpu_collision_event_count = 2;
    report.gpu_spawned_particle_count = 3;
    report.gpu_dropped_spawn_count = 4;
    report.gpu_compacted_particle_count = 7;
    scene.apply_particle_simulation_readback_stats(&report);

    let stats = scene.particle_frame_stats();
    assert_eq!(stats.live_particle_count, 2);
    assert_eq!(stats.gpu_alive_particle_count, 7);
    assert_eq!(stats.gpu_expired_particle_count, 1);
    assert_eq!(stats.gpu_collision_event_count, 2);
    assert_eq!(stats.gpu_spawned_particle_count, 3);
    assert_eq!(stats.gpu_dropped_spawn_count, 4);
    assert_eq!(stats.gpu_compacted_particle_count, 7);
    assert_eq!(stats.dropped_spawn_count(), 4);
    assert_eq!(
        stats.runtime_pressure_level,
        ParticleRuntimePressureLevel::Critical
    );
    let entity_stats = stats
        .emitter_stats_for(Some(entity.raw_value()))
        .expect("entity stats");
    assert_eq!(entity_stats.spawned_particle_count(), 2);
}

/// Gravity and velocity integrate with semi-implicit Euler.
#[test]
fn motion_integration() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 100.0;
        settings.shape.spawn_radius = 0.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::new(0.0, -10.0, 0.0);
    });
    emitter.emit(1, None);
    advance(&mut emitter, 1.0);
    let particle = emitter.particles()[0];
    // v += g*dt → -10
    assert!((particle.velocity.y + 10.0).abs() < 1e-4);
    // p += v*dt → -10
    assert!((particle.position.y + 10.0).abs() < 1e-4);
}

/// Radial force accelerates particles away from the force center.
#[test]
fn radial_force() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 10.0;
        settings.shape.origin_offset = Float3::new(1.0, 0.0, 0.0);
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.forces.force_mode = ParticleForceMode::Radial;
        settings.forces.force_radius = 0.0;
        settings.forces.force_strength = 2.0;
        settings.forces.force_falloff = 0.0;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 1.0);

    let particle = emitter.particles()[0];
    assert!((particle.velocity.x - 2.0).abs() < 1e-4);
    assert!((particle.position.x - 3.0).abs() < 1e-4);
}

/// Vortex force accelerates particles around the configured axis.
#[test]
fn vortex_force() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 10.0;
        settings.shape.origin_offset = Float3::new(1.0, 0.0, 0.0);
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.forces.force_mode = ParticleForceMode::Vortex;
        settings.forces.force_axis = Float3::new(0.0, 1.0, 0.0);
        settings.forces.force_radius = 0.0;
        settings.forces.force_strength = 3.0;
        settings.forces.force_falloff = 0.0;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 1.0);

    let particle = emitter.particles()[0];
    assert!((particle.velocity.z + 3.0).abs() < 1e-4);
    assert!((particle.position.z + 3.0).abs() < 1e-4);
}

/// Uniform vector field accelerates particles in the configured direction.
#[test]
fn uniform_vector_field() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.forces.vector_field_mode = ParticleVectorFieldMode::Uniform;
        settings.forces.vector_field_direction = Float3::new(2.0, 0.0, 0.0);
        settings.forces.vector_field_strength = 4.0;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 0.5);

    let particle = emitter.particles()[0];
    assert!((particle.velocity.x - 2.0).abs() < 1e-4);
    assert!((particle.position.x - 1.0).abs() < 1e-4);
    assert!((particle.velocity.y).abs() < 1e-4);
    assert!((particle.position.y).abs() < 1e-4);
}

/// The GPU plan reports its dispatch shape and which modules force a CPU
/// fallback.
#[test]
fn gpu_simulation_plan() {
    let supported = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 130;
        settings.appearance.lifetime = 10.0;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
        settings.gpu_simulation.workgroup_size = 64;
    });
    let supported_plan = supported.gpu_simulation_plan();
    assert_eq!(
        supported_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(supported_plan.uses_gpu());
    assert_eq!(supported_plan.particle_capacity, 130);
    assert_eq!(supported_plan.workgroup_size, 64);
    assert_eq!(supported_plan.dispatch_workgroups, 3);
    assert!(supported_plan.unsupported_reasons.is_empty());

    let clamped = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 513;
        settings.appearance.lifetime = 10.0;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
        settings.gpu_simulation.workgroup_size = 512;
    });
    let clamped_plan = clamped.gpu_simulation_plan();
    assert_eq!(
        clamped_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert_eq!(
        clamped_plan.workgroup_size,
        ParticleGPUSimulationPlan::MAXIMUM_WORKGROUP_SIZE
    );
    assert_eq!(clamped_plan.dispatch_workgroups, 3);

    let distance_emission = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 2.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
    });
    let distance_emission_plan = distance_emission.gpu_simulation_plan();
    assert_eq!(
        distance_emission_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(distance_emission_plan.uses_gpu());
    assert!(distance_emission_plan.unsupported_reasons.is_empty());

    let complex_fallback = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.forces.noise_strength = 1.0;
        settings.forces.force_mode = ParticleForceMode::Radial;
        settings.forces.force_strength = 2.0;
        settings.forces.vector_field_mode = ParticleVectorFieldMode::Uniform;
        settings.forces.vector_field_strength = 3.0;
        settings.collision.collision_mode = ParticleCollisionMode::LocalPlane;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
        settings.appearance.angular_velocity = 0.25;
    });
    let complex_fallback_plan = complex_fallback.gpu_simulation_plan();
    assert_eq!(
        complex_fallback_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(complex_fallback_plan.uses_gpu());
    assert!(complex_fallback_plan.unsupported_reasons.is_empty());

    let noise_plan = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.forces.noise_strength = 2.0;
        settings.forces.noise_scale = 3.0;
        settings.forces.noise_speed = 0.5;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
    })
    .gpu_simulation_plan();
    assert_eq!(
        noise_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(noise_plan.uses_gpu());

    let force_plan = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.forces.force_mode = ParticleForceMode::Vortex;
        settings.forces.force_axis = Float3::new(0.0, 1.0, 0.0);
        settings.forces.force_radius = 8.0;
        settings.forces.force_strength = -3.0;
        settings.forces.force_falloff = 2.0;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
    })
    .gpu_simulation_plan();
    assert_eq!(
        force_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(force_plan.uses_gpu());

    let uniform_vector_field_plan = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.forces.vector_field_mode = ParticleVectorFieldMode::Uniform;
        settings.forces.vector_field_direction = Float3::new(2.0, 0.0, 0.0);
        settings.forces.vector_field_strength = 4.0;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
    })
    .gpu_simulation_plan();
    assert_eq!(
        uniform_vector_field_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(uniform_vector_field_plan.uses_gpu());

    let angular_velocity_plan = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
        settings.appearance.angular_velocity = 0.25;
        settings.appearance.angular_velocity_randomness = 0.1;
    })
    .gpu_simulation_plan();
    assert_eq!(
        angular_velocity_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(angular_velocity_plan.uses_gpu());

    let plane_collision_plan = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.collision.collision_mode = ParticleCollisionMode::WorldPlane;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
        settings.collision.collision_plane_y = -1.0;
        settings.collision.collision_restitution = 0.25;
        settings.collision.collision_damping = 0.5;
    })
    .gpu_simulation_plan();
    assert_eq!(
        plane_collision_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(plane_collision_plan.uses_gpu());

    let required = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Death;
        settings.sub_emitters.legacy_burst_count = 1;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuRequired;
    });
    let required_plan = required.gpu_simulation_plan();
    assert_eq!(
        required_plan.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(required_plan.uses_gpu());
    assert!(required_plan.unsupported_reasons.is_empty());

    let collision_event_required = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Collision;
        settings.sub_emitters.legacy_burst_count = 1;
        settings.collision.collision_mode = ParticleCollisionMode::WorldPlane;
        settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuRequired;
    })
    .gpu_simulation_plan();
    assert_eq!(
        collision_event_required.status,
        ParticleGPUSimulationPlanStatus::Supported
    );
    assert!(collision_event_required.uses_gpu());
    assert!(collision_event_required.unsupported_reasons.is_empty());
}

/// `max_particles` caps the live pool.
#[test]
fn max_particles_cap() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 10_000.0;
        settings.emission.max_particles = 5;
        settings.appearance.lifetime = 1000.0;
        settings.forces.gravity = Float3::ZERO;
    });
    for _ in 0..10 {
        advance(&mut emitter, 0.1);
    }
    assert_eq!(emitter.alive_count(), 5);
    emitter.emit(100, None);
    assert_eq!(emitter.alive_count(), 5);
}

/// Identical seeds produce identical simulations.
#[test]
fn deterministic_with_seed() {
    fn run() -> Vec<Particle> {
        let mut emitter = emitter_with(|settings| {
            settings.emission.emission_rate = 50.0;
            settings.emission.max_particles = 64;
            settings.appearance.lifetime = 5.0;
            settings.shape.spawn_radius = 1.0;
            settings.velocity.velocity_randomness = Float3::new(2.0, 2.0, 2.0);
            settings.forces.gravity = Float3::new(0.0, -9.81, 0.0);
            settings.emission.seed = 42;
        });
        for _ in 0..20 {
            advance(&mut emitter, 1.0 / 60.0);
        }
        emitter.particles().to_vec()
    }
    assert_eq!(run(), run());
}

/// Box emission spawns within the configured half extents.
#[test]
fn box_emission_shape() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.shape.emission_shape = ParticleEmissionShape::Box;
        settings.shape.box_half_extents = Float3::new(2.0, 3.0, 4.0);
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.emission.seed = 7;
    });
    emitter.emit(32, None);

    assert_eq!(emitter.alive_count(), 32);
    for particle in emitter.particles() {
        assert!(particle.position.x.abs() <= 2.0);
        assert!(particle.position.y.abs() <= 3.0);
        assert!(particle.position.z.abs() <= 4.0);
    }
}

/// Cone emission spawns inside a cone volume oriented by the start velocity.
#[test]
fn cone_emission_shape() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 64;
        settings.appearance.lifetime = 10.0;
        settings.shape.emission_shape = ParticleEmissionShape::Cone;
        settings.shape.cone_radius = 2.0;
        settings.shape.cone_height = 5.0;
        settings.velocity.start_velocity = Float3::new(0.0, 1.0, 0.0);
        settings.forces.gravity = Float3::ZERO;
        settings.emission.seed = 11;
    });
    emitter.emit(32, None);

    assert_eq!(emitter.alive_count(), 32);
    for particle in emitter.particles() {
        assert!(particle.position.y >= 0.0);
        assert!(particle.position.y <= 5.0);
        let radial = (particle.position.x * particle.position.x
            + particle.position.z * particle.position.z)
            .sqrt();
        let allowed_radius = 2.0 * (particle.position.y / 5.0);
        assert!(radial <= allowed_radius + 0.0001);
    }
}

/// Local plane collision bounces particles and damps tangent velocity.
#[test]
fn local_plane_collision() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 100.0;
        settings.velocity.start_velocity = Float3::new(4.0, 0.0, 0.0);
        settings.forces.gravity = Float3::new(0.0, -10.0, 0.0);
        settings.collision.collision_mode = ParticleCollisionMode::LocalPlane;
        settings.collision.collision_plane_y = 0.0;
        settings.collision.collision_restitution = 0.5;
        settings.collision.collision_damping = 0.25;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 1.0);

    let particle = emitter.particles()[0];
    assert!(particle.position.y.abs() < 1e-4);
    assert!((particle.velocity.y - 5.0).abs() < 1e-4);
    assert!((particle.velocity.x - 3.0).abs() < 1e-4);
}

/// World plane collision uses the entity world transform.
#[test]
fn world_plane_collision() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(WorldTransform::new(translated(0.0, 5.0, 0.0)), entity);

    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 100.0;
        settings.velocity.start_velocity = Float3::new(4.0, 0.0, 0.0);
        settings.forces.gravity = Float3::new(0.0, -10.0, 0.0);
        settings.collision.collision_mode = ParticleCollisionMode::WorldPlane;
        settings.collision.collision_plane_y = 0.0;
        settings.collision.collision_restitution = 0.5;
        settings.collision.collision_damping = 0.25;
    });
    emitter.emit(1, None);
    let _ = scene.set_component(emitter, entity);

    assert_eq!(
        scene.advance_particles(1.0, ParticleAdvanceOptions::default()),
        1
    );

    let particle = scene
        .component::<ParticleEmitter>(entity)
        .expect("particle emitter")
        .particles()[0];
    assert!((particle.position.y + 5.0).abs() < 1e-4);
    assert!((particle.velocity.y - 5.0).abs() < 1e-4);
    assert!((particle.velocity.x - 3.0).abs() < 1e-4);
}

/// `isEmitting = false` stops new spawns but still ages live particles.
#[test]
fn stopped_emitter_still_ages() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 100.0;
        settings.appearance.lifetime = 0.5;
        settings.forces.gravity = Float3::ZERO;
    });
    emitter.emit(4, None);
    emitter.settings.emission.is_emitting = false;
    assert_eq!(emitter.alive_count(), 4);
    // aged out, none replaced
    advance(&mut emitter, 0.6);
    assert_eq!(emitter.alive_count(), 0);
}

/// Appearance lerps from start to end across the lifetime.
#[test]
fn appearance_gradient() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 1.0;
        settings.forces.gravity = Float3::ZERO;
        settings.appearance.start_size = 2.0;
        settings.appearance.end_size = 0.0;
        settings.appearance.start_color = Float4::new(1.0, 1.0, 1.0, 1.0);
        settings.appearance.end_color = Float4::new(1.0, 1.0, 1.0, 0.0);
    });
    emitter.emit(1, None);
    // halfway through life
    advance(&mut emitter, 0.5);
    let particle = emitter.particles()[0];
    // lerp(2, 0, 0.5) = 1
    assert!((particle.size - 1.0).abs() < 1e-4);
    // alpha lerp(1, 0, 0.5) = 0.5
    assert!((particle.color.w - 0.5).abs() < 1e-4);
}

/// Appearance curves remap the normalized age for size and color.
#[test]
fn appearance_curves() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 1.0;
        settings.forces.gravity = Float3::ZERO;
        settings.appearance.start_size = 0.0;
        settings.appearance.end_size = 1.0;
        settings.appearance.size_curve = ParticleCurve::EaseIn;
        settings.appearance.start_color = Float4::new(1.0, 1.0, 1.0, 0.0);
        settings.appearance.end_color = Float4::new(1.0, 1.0, 1.0, 1.0);
        settings.appearance.color_curve = ParticleCurve::EaseOut;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 0.5);

    let particle = emitter.particles()[0];
    assert!((particle.size - 0.25).abs() < 1e-4);
    assert!((particle.color.w - 0.75).abs() < 1e-4);
}

/// Size randomness applies stable per-particle scales.
#[test]
fn size_randomness() {
    fn run() -> Vec<Particle> {
        let mut emitter = emitter_with(|settings| {
            settings.emission.emission_rate = 0.0;
            settings.emission.max_particles = 8;
            settings.appearance.lifetime = 1.0;
            settings.forces.gravity = Float3::ZERO;
            settings.appearance.start_size = 2.0;
            settings.appearance.end_size = 2.0;
            settings.appearance.size_randomness = 0.5;
            settings.emission.seed = 99;
        });
        emitter.emit(4, None);
        advance(&mut emitter, 0.25);
        emitter.particles().to_vec()
    }

    let particles = run();
    assert_eq!(particles, run());
    assert!(
        particles
            .iter()
            .all(|particle| particle.size >= 1.0 && particle.size <= 3.0)
    );
    assert!(
        particles
            .iter()
            .any(|particle| (particle.size - 2.0).abs() > 0.0001)
    );
}

/// Particle rotation integrates angular velocity.
#[test]
fn particle_rotation() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 4;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.appearance.start_rotation = 0.25;
        settings.appearance.angular_velocity = 2.0;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 0.5);

    let particle = emitter.particles()[0];
    assert!((particle.rotation - 1.25).abs() < 1e-4);
    assert!((particle.angular_velocity - 2.0).abs() < 1e-4);
}

/// World simulation space spawns and stores particles in world coordinates.
#[test]
fn world_simulation_space_stores_world_particles() {
    let transform = translated(10.0, 0.0, 0.0);
    let mut emitter = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 4;
        settings.appearance.lifetime = 10.0;
        settings.shape.origin_offset = Float3::new(1.0, 0.0, 0.0);
        settings.velocity.start_velocity = Float3::new(0.0, 2.0, 0.0);
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });
    emitter.emit(1, Some(transform));

    assert_eq!(emitter.particles().len(), 1);
    assert_eq!(emitter.particles()[0].position, Float3::new(11.0, 0.0, 0.0));
    assert_eq!(emitter.particles()[0].velocity, Float3::new(0.0, 2.0, 0.0));
    advance_within(&mut emitter, 0.5, MATRIX_IDENTITY_FLOAT4X4);
    assert_eq!(emitter.particles()[0].position, Float3::new(11.0, 1.0, 0.0));
}

/// `SceneRuntime.emit_particles` passes the entity transform for world-space
/// emitters.
#[test]
fn scene_emit_particles_uses_world_transform_for_world_space_emitters() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        entity,
    );
    scene.propagate_transforms();
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.is_emitting = false;
            settings.emission.emission_rate = 0.0;
            settings.emission.max_particles = 2;
            settings.appearance.lifetime = 10.0;
            settings.velocity.start_velocity = Float3::ZERO;
            settings.forces.gravity = Float3::ZERO;
            settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
        }),
        entity,
    );

    let emitted = scene.emit_particles(entity, 1);
    assert!(emitted);
    assert_eq!(
        scene
            .component::<ParticleEmitter>(entity)
            .expect("particle emitter")
            .particles()[0]
            .position,
        Float3::new(4.0, 0.0, 0.0)
    );
}

/// Keyframe curves linearly interpolate sorted keys.
#[test]
fn appearance_keyframe_curves() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 1.0;
        settings.forces.gravity = Float3::ZERO;
        settings.appearance.start_size = 0.0;
        settings.appearance.end_size = 10.0;
        settings.appearance.size_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(1.0, 0.0),
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(0.5, 1.0),
        ]);
        settings.appearance.start_color = Float4::new(1.0, 1.0, 1.0, 0.0);
        settings.appearance.end_color = Float4::new(1.0, 1.0, 1.0, 1.0);
        settings.appearance.color_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(1.0, 0.5),
        ]);
    });
    emitter.emit(1, None);
    advance(&mut emitter, 0.25);

    let particle = emitter.particles()[0];
    assert!((particle.size - 5.0).abs() < 1e-4);
    assert!((particle.color.w - 0.125).abs() < 1e-4);
}

/// `ParticleCurve` evaluates presets and keyframes.
#[test]
fn particle_curve_evaluation() {
    assert_eq!(ParticleCurve::Constant(2.5).evaluate(-1.0), 2.5);
    assert_eq!(ParticleCurve::Constant(2.5).evaluate(2.0), 2.5);
    assert_eq!(ParticleCurve::Linear.evaluate(-1.0), 0.0);
    assert_eq!(ParticleCurve::Linear.evaluate(2.0), 1.0);
    assert!((ParticleCurve::EaseIn.evaluate(0.5) - 0.25).abs() < 1e-4);
    assert!((ParticleCurve::EaseOut.evaluate(0.5) - 0.75).abs() < 1e-4);
    assert!((ParticleCurve::EaseInOut.evaluate(0.25) - 0.125).abs() < 1e-4);

    let curve = ParticleCurve::Keyframes(vec![
        ParticleCurveKeyframe::new(1.0, 0.0),
        ParticleCurveKeyframe::new(0.0, 0.0),
        ParticleCurveKeyframe::new(0.5, 1.0),
    ]);
    assert!((curve.evaluate(0.25) - 0.5).abs() < 1e-4);
    assert!((curve.evaluate(0.75) - 0.5).abs() < 1e-4);
    let (minimum, maximum) = curve.conservative_value_range();
    assert_eq!(minimum, 0.0);
    assert_eq!(maximum, 1.0);

    let (overshoot_minimum, overshoot_maximum) = ParticleCurve::Keyframes(vec![
        ParticleCurveKeyframe::new(0.0, -0.5),
        ParticleCurveKeyframe::new(0.5, 3.0),
        ParticleCurveKeyframe::new(1.0, 0.25),
    ])
    .conservative_value_range();
    assert_eq!(overshoot_minimum, -0.5);
    assert_eq!(overshoot_maximum, 3.0);
}

/// The emission rate curve modulates the continuous spawn rate over the emitter
/// duration.
#[test]
fn emission_rate_curve_modulates_continuous_emission() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.looping = false;
        settings.emission.duration = 2.0;
        settings.emission.emission_rate = 10.0;
        settings.emission.emission_rate_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(1.0, 2.0),
        ]);
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });

    advance(&mut emitter, 1.0);
    assert_eq!(emitter.alive_count(), 5);
    advance(&mut emitter, 1.0);
    assert_eq!(emitter.alive_count(), 20);
}

/// Looping emission curves are averaged across long frames.
#[test]
fn looping_emission_curves_are_averaged_across_long_frames() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.looping = true;
        settings.emission.duration = 1.0;
        settings.emission.emission_rate = 10.0;
        settings.emission.emission_rate_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(1.0, 2.0),
        ]);
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });

    advance(&mut emitter, 2.0);

    assert_eq!(emitter.alive_count(), 20);
    let stats = emitter.last_frame_stats();
    assert_eq!(stats.requested_spawn_count, 20);
    assert_eq!(stats.continuous_spawned_count, 20);
}

/// The distance emission rate curve modulates the movement-based spawn rate.
#[test]
fn distance_emission_rate_curve_modulates_distance_emission() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.looping = false;
        settings.emission.duration = 2.0;
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 10.0;
        settings.emission.distance_emission_rate_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(1.0, 2.0),
        ]);
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });
    let mut transform = MATRIX_IDENTITY_FLOAT4X4;

    advance_within(&mut emitter, 0.01, transform);
    transform.columns[3].x = 1.0;
    advance_within(&mut emitter, 1.0, transform);
    assert_eq!(emitter.alive_count(), 5);
    transform.columns[3].x = 2.0;
    advance_within(&mut emitter, 1.0, transform);
    assert_eq!(emitter.alive_count(), 20);
}

/// Looping distance emission curves are averaged across long frames.
#[test]
fn looping_distance_emission_curves_are_averaged_across_long_frames() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.looping = true;
        settings.emission.duration = 1.0;
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 10.0;
        settings.emission.distance_emission_rate_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(1.0, 2.0),
        ]);
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.gpu_simulation.simulation_space = ParticleSimulationSpace::World;
    });
    let mut transform = MATRIX_IDENTITY_FLOAT4X4;

    advance_within(&mut emitter, 0.01, transform);
    transform.columns[3].x = 2.0;
    advance_within(&mut emitter, 2.0, transform);

    assert_eq!(emitter.alive_count(), 20);
    let stats = emitter.last_frame_stats();
    assert_eq!(stats.requested_spawn_count, 20);
    assert_eq!(stats.distance_spawned_count, 20);
}

/// Prewarm simulates once before the first active tick.
#[test]
fn prewarm_simulates_before_first_tick() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.prewarm_time = 1.0;
        settings.emission.prewarm_step = 0.5;
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
    });

    advance(&mut emitter, 0.1);
    assert_eq!(emitter.alive_count(), 11);
    advance(&mut emitter, 0.1);
    assert_eq!(emitter.alive_count(), 12);

    emitter.clear();
    advance(&mut emitter, 0.1);
    assert_eq!(emitter.alive_count(), 11);
}

/// Texture sheet UV rect advances over lifetime or frame rate.
#[test]
fn texture_sheet_uv_rect() {
    let mut lifetime_emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 1.0;
        settings.forces.gravity = Float3::ZERO;
        settings.texture_sheet.columns = 2;
        settings.texture_sheet.rows = 2;
        settings.texture_sheet.frame_count = 4;
    });
    lifetime_emitter.emit(1, None);
    advance(&mut lifetime_emitter, 0.5);
    assert_eq!(
        lifetime_emitter.texture_uv_rect(&lifetime_emitter.particles()[0]),
        Float4::new(0.0, 0.5, 0.5, 0.5)
    );

    let mut rate_emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 10.0;
        settings.forces.gravity = Float3::ZERO;
        settings.texture_sheet.columns = 4;
        settings.texture_sheet.rows = 1;
        settings.texture_sheet.frame_count = 4;
        settings.texture_sheet.frame_rate = 2.0;
    });
    rate_emitter.emit(1, None);
    advance(&mut rate_emitter, 1.5);
    assert_eq!(
        rate_emitter.texture_uv_rect(&rate_emitter.particles()[0]),
        Float4::new(0.75, 0.0, 0.25, 1.0)
    );
}

/// Texture sheet playback supports ranges, loops, and stable random start
/// frames.
#[test]
fn texture_sheet_playback_modes() {
    let particle = Particle::new(
        Float3::ZERO,
        Float3::ZERO,
        2.0,
        10.0,
        1.0,
        0.0,
        0.0,
        1.0,
        Float4::new(1.0, 1.0, 1.0, 1.0),
        0,
        0,
        5,
    );

    let play_once = emitter_with(|settings| {
        settings.texture_sheet.columns = 4;
        settings.texture_sheet.rows = 2;
        settings.texture_sheet.frame_count = 3;
        settings.texture_sheet.frame_rate = 2.0;
        settings.texture_sheet.playback_mode = ParticleTextureSheetPlaybackMode::PlayOnce;
        settings.texture_sheet.start_frame = 2;
    });
    assert_eq!(play_once.texture_sheet_frame_index(&particle), 4);
    assert_eq!(
        play_once.texture_uv_rect(&particle),
        Float4::new(0.0, 0.5, 0.25, 0.5)
    );

    let loop_emitter = emitter_with(|settings| {
        settings.texture_sheet.columns = 4;
        settings.texture_sheet.rows = 2;
        settings.texture_sheet.frame_count = 3;
        settings.texture_sheet.frame_rate = 2.0;
        settings.texture_sheet.playback_mode = ParticleTextureSheetPlaybackMode::Loop;
        settings.texture_sheet.start_frame = 2;
    });
    assert_eq!(loop_emitter.texture_sheet_frame_index(&particle), 3);
    assert_eq!(
        loop_emitter.texture_uv_rect(&particle),
        Float4::new(0.75, 0.0, 0.25, 0.5)
    );

    let random_single_frame = emitter_with(|settings| {
        settings.texture_sheet.columns = 4;
        settings.texture_sheet.rows = 2;
        settings.texture_sheet.frame_count = 3;
        settings.texture_sheet.playback_mode = ParticleTextureSheetPlaybackMode::SingleFrame;
        settings.texture_sheet.start_frame = 2;
        settings.texture_sheet.frame_randomness = 2;
    });
    assert_eq!(random_single_frame.texture_sheet_frame_index(&particle), 4);
}

/// Trail configuration is sanitized at construction.
#[test]
fn trail_configuration_sanitizes() {
    let emitter = emitter_with(|settings| {
        settings.trails.ribbon_width_scale = -1.0;
        settings.trails.ribbon_tail_width_scale = -0.5;
        settings.trails.ribbon_tail_alpha_scale = 2.0;
        settings.trails.ribbon_max_segment_length = -4.0;
        settings.trails.ribbon_join_overlap_scale = -1.0;
        settings.trails.ribbon_smoothing_segments = -2;
        settings.trails.ribbon_texture_tiling = -2.0;
        settings.trails.ribbon_texture_offset = -0.25;
        settings.trails.trail_length = -1.0;
        settings.trails.trail_segments = -4;
        settings.trails.trail_end_size_scale = -0.5;
        settings.trails.trail_end_alpha_scale = 2.0;
    });

    assert_eq!(emitter.settings.trails.trail_length, 0.0);
    assert_eq!(emitter.settings.trails.trail_segments, 0);
    assert_eq!(emitter.settings.trails.trail_end_size_scale, 0.0);
    assert_eq!(emitter.settings.trails.trail_end_alpha_scale, 1.0);
    assert_eq!(emitter.settings.trails.ribbon_width_scale, 0.0);
    assert_eq!(emitter.settings.trails.ribbon_tail_width_scale, 0.0);
    assert_eq!(emitter.settings.trails.ribbon_tail_alpha_scale, 1.0);
    assert_eq!(emitter.settings.trails.ribbon_max_segment_length, 0.0);
    assert_eq!(emitter.settings.trails.ribbon_join_overlap_scale, 0.0);
    assert_eq!(emitter.settings.trails.ribbon_smoothing_segments, 1);
    assert_eq!(emitter.settings.trails.ribbon_texture_tiling, 0.0);
    assert_eq!(emitter.settings.trails.ribbon_texture_offset, -0.25);
}

/// The automatic render bounds estimate covers configured motion and billboard
/// size.
#[test]
fn automatic_render_bounds_estimate() {
    let emitter = emitter_with(|settings| {
        settings.appearance.lifetime = 2.0;
        settings.shape.spawn_radius = 1.0;
        settings.velocity.start_velocity = Float3::new(2.0, 0.0, 0.0);
        settings.velocity.velocity_randomness = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.appearance.start_size = 2.0;
        settings.appearance.end_size = 1.0;
        settings.renderer.render_bounds_mode = ParticleRenderBoundsMode::Automatic;
    });

    let estimated = emitter.estimated_render_bounds_radius();

    assert!(estimated > 6.4);
    assert!((emitter.effective_render_bounds_radius() - estimated).abs() < 0.0001);
}

/// The automatic render bounds estimate includes size curve keyframe overshoot.
#[test]
fn automatic_render_bounds_estimate_includes_size_curve_overshoot() {
    let baseline = emitter_with(|settings| {
        settings.appearance.lifetime = 1.0;
        settings.shape.spawn_radius = 0.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.appearance.start_size = 1.0;
        settings.appearance.end_size = 2.0;
        settings.renderer.render_bounds_mode = ParticleRenderBoundsMode::Automatic;
    });
    let oversized = emitter_with(|settings| {
        settings.appearance.lifetime = 1.0;
        settings.shape.spawn_radius = 0.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.appearance.start_size = 1.0;
        settings.appearance.end_size = 2.0;
        settings.appearance.size_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(0.5, 40.0),
            ParticleCurveKeyframe::new(1.0, 1.0),
        ]);
        settings.renderer.render_bounds_mode = ParticleRenderBoundsMode::Automatic;
    });

    assert!(
        oversized.estimated_render_bounds_radius()
            > baseline.estimated_render_bounds_radius() * 10.0
    );
}

/// Manual render bounds preserve the legacy radius behavior.
#[test]
fn manual_render_bounds_preserve_legacy_radius() {
    let emitter = emitter_with(|settings| {
        settings.renderer.render_bounds_radius = 12.0;
        settings.renderer.render_bounds_mode = if settings.renderer.render_bounds_radius > 0.0 {
            ParticleRenderBoundsMode::Manual
        } else {
            ParticleRenderBoundsMode::Disabled
        };
    });

    assert_eq!(
        emitter.settings.renderer.render_bounds_mode,
        ParticleRenderBoundsMode::Manual
    );
    assert_eq!(emitter.effective_render_bounds_radius(), 12.0);
}

/// Render LOD scales the particle submission budget by camera distance.
#[test]
fn render_lod_scales_submission_budget() {
    let emitter = emitter_with(|settings| {
        settings.emission.max_rendered_particles = 100;
        settings.renderer.render_lod_start_distance = 10.0;
        settings.renderer.render_lod_end_distance = 30.0;
        settings.renderer.render_lod_min_particle_scale = 0.25;
    });

    assert_eq!(emitter.render_lod_scale(0.0), 1.0);
    assert_eq!(emitter.render_lod_scale(30.0), 0.25);
    assert_eq!(emitter.effective_max_rendered_particles(20.0, 200), 63);
    assert_eq!(emitter.effective_max_rendered_particles(30.0, 200), 25);
}

/// Advance options scale continuous, burst, distance emission, and the live cap.
#[test]
fn advance_options_scale_emission() {
    let mut continuous = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 100.0;
        settings.forces.gravity = Float3::ZERO;
    });
    continuous.advance(1.0, None, &ParticleAdvanceOptions::new(0.5, 1.0, 1.0, 1.0));
    assert_eq!(continuous.alive_count(), 5);

    let mut burst = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.burst_count = 3;
        settings.emission.burst_interval = 1.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 100.0;
        settings.forces.gravity = Float3::ZERO;
    });
    burst.advance(1.0, None, &ParticleAdvanceOptions::new(1.0, 0.5, 1.0, 1.0));
    assert_eq!(burst.alive_count(), 1);
    burst.advance(1.0, None, &ParticleAdvanceOptions::new(1.0, 0.5, 1.0, 1.0));
    assert_eq!(burst.alive_count(), 3);

    let mut distance = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.emission.distance_emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 100.0;
        settings.forces.gravity = Float3::ZERO;
    });
    distance.advance(
        0.01,
        Some(MATRIX_IDENTITY_FLOAT4X4),
        &ParticleAdvanceOptions::default(),
    );
    let moved = translated(1.0, 0.0, 0.0);
    distance.advance(
        0.01,
        Some(moved),
        &ParticleAdvanceOptions::new(1.0, 1.0, 0.25, 1.0),
    );
    assert_eq!(distance.alive_count(), 2);

    let mut capped = emitter_with(|settings| {
        settings.emission.emission_rate = 100.0;
        settings.emission.max_particles = 10;
        settings.appearance.lifetime = 100.0;
        settings.forces.gravity = Float3::ZERO;
    });
    capped.advance(1.0, None, &ParticleAdvanceOptions::new(1.0, 1.0, 1.0, 0.5));
    assert_eq!(capped.alive_count(), 5);
}

/// The schedule applies the particle scalability resource during simulation.
#[test]
fn schedule_applies_particle_scalability_resource() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    scene.set_resource(ParticleScalabilityResource::new(0.25, 1.0, 1.0, 0.5));
    let entity = scene.create_entity();
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.emission_rate = 20.0;
            settings.emission.max_particles = 100;
            settings.appearance.lifetime = 100.0;
            settings.forces.gravity = Float3::ZERO;
        }),
        entity,
    );

    let _ = scene.tick(1.0, 0, Vec::new());

    assert_eq!(
        scene
            .component::<ParticleEmitter>(entity)
            .expect("particle emitter")
            .alive_count(),
        5
    );
}

/// Emitter frame stats report spawn, expire, collision, and capacity pressure.
#[test]
fn emitter_frame_stats_report_simulation_work() {
    let mut capped = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 5;
        settings.appearance.lifetime = 0.5;
        settings.forces.gravity = Float3::ZERO;
    });
    capped.advance(1.0, None, &ParticleAdvanceOptions::default());
    let stats = capped.last_frame_stats();
    assert_eq!(stats.continuous_spawned_count, 5);
    assert_eq!(stats.capacity_limited_spawn_count, 5);
    assert_eq!(stats.spawned_particle_count(), 5);
    assert_eq!(stats.live_particle_count, 5);

    capped.advance(1.0, None, &ParticleAdvanceOptions::default());
    let stats = capped.last_frame_stats();
    assert_eq!(stats.expired_particle_count, 5);
    assert_eq!(stats.continuous_spawned_count, 5);
    assert_eq!(stats.capacity_limited_spawn_count, 5);
    assert_eq!(stats.live_particle_count, 5);

    let mut collision = emitter_with(|settings| {
        settings.emission.is_emitting = false;
        settings.emission.emission_rate = 0.0;
        settings.emission.max_particles = 3;
        settings.appearance.lifetime = 10.0;
        settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Collision;
        settings.sub_emitters.legacy_burst_count = 5;
        settings.sub_emitters.legacy_lifetime = 2.0;
        settings.shape.origin_offset = Float3::new(0.0, 0.5, 0.0);
        settings.velocity.start_velocity = Float3::new(0.0, -1.0, 0.0);
        settings.forces.gravity = Float3::ZERO;
        settings.collision.collision_mode = ParticleCollisionMode::LocalPlane;
        settings.collision.collision_plane_y = 0.0;
    });
    collision.emit(1, None);
    collision.advance(1.0, None, &ParticleAdvanceOptions::default());
    let stats = collision.last_frame_stats();
    assert_eq!(stats.collision_count, 1);
    assert_eq!(stats.sub_emitter_spawned_count, 2);
    assert_eq!(stats.capacity_limited_spawn_count, 3);
    assert_eq!(stats.live_particle_count, 3);
}

/// The schedule publishes aggregate particle frame stats.
#[test]
fn schedule_publishes_particle_frame_stats() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let a = scene.create_entity();
    let b = scene.create_entity();
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.emission_rate = 10.0;
            settings.emission.max_particles = 100;
            settings.appearance.lifetime = 100.0;
            settings.forces.gravity = Float3::ZERO;
        }),
        a,
    );
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.emission_rate = 4.0;
            settings.emission.max_particles = 100;
            settings.appearance.lifetime = 100.0;
            settings.forces.gravity = Float3::ZERO;
        }),
        b,
    );

    let _ = scene.tick(1.0, 0, Vec::new());

    let stats = scene.particle_frame_stats();
    assert_eq!(stats.emitter_count, 2);
    assert_eq!(stats.active_emitter_count, 2);
    assert_eq!(stats.continuous_spawned_count, 14);
    assert_eq!(stats.spawned_particle_count, 14);
    assert_eq!(stats.live_particle_count, 14);
    assert_eq!(stats.max_particle_count, 200);
    let a_stats = stats
        .emitter_stats_for(Some(a.raw_value()))
        .expect("entity a stats");
    assert_eq!(a_stats.spawned_particle_count(), 10);
    assert_eq!(a_stats.live_particle_count, 10);
    let b_stats = stats
        .emitter_stats_for(Some(b.raw_value()))
        .expect("entity b stats");
    assert_eq!(b_stats.spawned_particle_count(), 4);
    assert_eq!(b_stats.live_particle_count, 4);
}

/// The particle scalability policy throttles simulation from the previous
/// frame's pressure.
#[test]
fn particle_scalability_policy_throttles_from_previous_frame_pressure() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    scene.set_resource(ParticleScalabilityPolicyResource::new(
        true, 10, 0, 0.5, 0.5, 0.1,
    ));
    let entity = scene.create_entity();
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.emission_rate = 40.0;
            settings.emission.max_particles = 100;
            settings.appearance.lifetime = 100.0;
            settings.forces.gravity = Float3::ZERO;
        }),
        entity,
    );

    let _ = scene.tick(1.0, 0, Vec::new());
    assert_eq!(
        scene
            .component::<ParticleEmitter>(entity)
            .expect("particle emitter")
            .alive_count(),
        40
    );
    let state = scene.particle_scalability_state();
    assert_eq!(state.applied_scale, 1.0);
    assert_eq!(state.reason, ParticleScalabilityPressureReason::None);

    let _ = scene.tick(1.0, 0, Vec::new());
    let state = scene.particle_scalability_state();
    assert!((state.applied_scale - 0.5).abs() < 0.0001);
    assert_eq!(state.reason, ParticleScalabilityPressureReason::LiveBudget);
    assert_eq!(
        scene
            .component::<ParticleEmitter>(entity)
            .expect("particle emitter")
            .alive_count(),
        50
    );
    assert_eq!(
        scene.particle_frame_stats().capacity_limited_spawn_count,
        10
    );
}

/// The particle scalability policy recovers when pressure clears.
#[test]
fn particle_scalability_policy_recovers_when_pressure_clears() {
    let policy = ParticleScalabilityPolicyResource::new(true, 100, 0, 0.25, 0.5, 0.2);

    let state = policy.updated_state(
        &ParticleFrameStatsResource::empty(),
        ParticleScalabilityStateResource::new(
            0.5,
            1.0,
            ParticleScalabilityPressureReason::LiveBudget,
        ),
    );

    assert!((state.applied_scale - 0.7).abs() < 0.0001);
    assert_eq!(state.reason, ParticleScalabilityPressureReason::None);
    assert_eq!(state.pressure, 0.0);
}

/// The particle scalability policy reports the dominant pressure reason.
#[test]
fn particle_scalability_policy_reports_dominant_pressure_reason() {
    let policy = ParticleScalabilityPolicyResource::new(true, 100, 20, 0.25, 0.2, 0.1);

    let live_pressure = policy.updated_state(
        &aggregate_stats(vec![frame_stats(|stats| {
            stats.live_particle_count = 180;
            stats.max_particle_count = 200;
            stats.live_particle_limit = 200;
            stats.continuous_spawned_count = 24;
        })]),
        ParticleScalabilityStateResource::default(),
    );
    assert_eq!(
        live_pressure.reason,
        ParticleScalabilityPressureReason::LiveBudget
    );
    assert!((live_pressure.pressure - 0.8).abs() < 0.0001);

    let spawn_pressure = policy.updated_state(
        &aggregate_stats(vec![frame_stats(|stats| {
            stats.live_particle_count = 120;
            stats.max_particle_count = 200;
            stats.live_particle_limit = 200;
            stats.continuous_spawned_count = 50;
        })]),
        ParticleScalabilityStateResource::default(),
    );
    assert_eq!(
        spawn_pressure.reason,
        ParticleScalabilityPressureReason::SpawnBudget
    );
    assert!((spawn_pressure.pressure - 1.5).abs() < 0.0001);

    let capacity_pressure = policy.updated_state(
        &aggregate_stats(vec![frame_stats(|stats| {
            stats.live_particle_count = 10;
            stats.max_particle_count = 10;
            stats.live_particle_limit = 10;
            stats.capacity_limited_spawn_count = 1;
        })]),
        ParticleScalabilityStateResource::default(),
    );
    assert_eq!(
        capacity_pressure.reason,
        ParticleScalabilityPressureReason::CapacityLimited
    );
    assert_eq!(capacity_pressure.pressure, 1.0);

    let spawn_budget_limited_pressure = policy.updated_state(
        &aggregate_stats(vec![frame_stats(|stats| {
            stats.live_particle_count = 10;
            stats.max_particle_count = 100;
            stats.live_particle_limit = 100;
            stats.spawn_budget_limited_count = 3;
        })]),
        ParticleScalabilityStateResource::default(),
    );
    assert_eq!(
        spawn_budget_limited_pressure.reason,
        ParticleScalabilityPressureReason::SpawnBudget
    );
    assert_eq!(spawn_budget_limited_pressure.pressure, 1.0);

    let gpu_drop_pressure = policy.updated_state(
        &ParticleFrameStatsResource::new(0.0, Vec::new(), BTreeMap::new(), 0, 0, 0, 0, 2, 0),
        ParticleScalabilityStateResource::default(),
    );
    assert_eq!(
        gpu_drop_pressure.reason,
        ParticleScalabilityPressureReason::SpawnBudget
    );
    assert_eq!(gpu_drop_pressure.pressure, 1.0);

    let mut gpu_live_stats = aggregate_stats(vec![frame_stats(|stats| {
        stats.live_particle_count = 10;
        stats.max_particle_count = 200;
        stats.live_particle_limit = 200;
    })]);
    gpu_live_stats.gpu_alive_particle_count = 180;
    let gpu_live_pressure =
        policy.updated_state(&gpu_live_stats, ParticleScalabilityStateResource::default());
    assert_eq!(
        gpu_live_pressure.reason,
        ParticleScalabilityPressureReason::LiveBudget
    );
    assert!((gpu_live_pressure.pressure - 0.8).abs() < 0.0001);
}

/// Particle frame stats expose live budget utilization and dropped spawns.
#[test]
fn particle_frame_stats_expose_live_budget_utilization_and_dropped_spawns() {
    let a = frame_stats(|stats| {
        stats.live_particle_count = 45;
        stats.max_particle_count = 100;
        stats.live_particle_limit = 50;
        stats.continuous_spawned_count = 10;
        stats.requested_spawn_count = 16;
        stats.spawn_budget_limit = 20;
        stats.spawn_budget_consumed_count = 12;
        stats.capacity_limited_spawn_count = 2;
        stats.spawn_budget_limited_count = 4;
    });
    let b = frame_stats(|stats| {
        stats.live_particle_count = 25;
        stats.max_particle_count = 200;
        stats.live_particle_limit = 0;
        stats.burst_spawned_count = 5;
        stats.requested_spawn_count = 8;
        stats.capacity_limited_spawn_count = 3;
    });
    let aggregate = ParticleFrameStatsResource::new(
        0.0,
        vec![a, b],
        BTreeMap::from([(11, a), (22, b)]),
        0,
        0,
        0,
        0,
        0,
        0,
    );
    let mut event_report = ParticleSimulationEventApplyReport::empty();
    event_report.gpu_dropped_spawn_count = 4;
    event_report.requested_spawn_count = 9;
    event_report.spawn_budget_limit = 10;
    event_report.spawn_budget_consumed_count = 6;
    event_report.capacity_limited_spawn_count = 2;
    event_report.spawn_budget_limited_count = 3;

    assert_eq!(a.live_particle_budget_limit(), 50);
    assert!((a.live_particle_budget_utilization() - 0.9).abs() < 0.0001);
    assert!((a.spawn_budget_utilization() - 0.6).abs() < 0.0001);
    assert_eq!(a.dropped_spawn_count(), 6);
    assert_eq!(
        a.runtime_pressure_level(),
        ParticleRuntimePressureLevel::Critical
    );
    assert_eq!(b.live_particle_budget_limit(), 200);
    assert!((b.live_particle_budget_utilization() - 0.125).abs() < 0.0001);
    assert_eq!(b.spawn_budget_utilization(), 0.0);
    assert_eq!(b.dropped_spawn_count(), 3);
    assert_eq!(
        b.runtime_pressure_level(),
        ParticleRuntimePressureLevel::Critical
    );

    assert_eq!(aggregate.live_particle_budget_limit, 250);
    assert!((aggregate.live_particle_budget_utilization() - 0.28).abs() < 0.0001);
    assert_eq!(aggregate.requested_spawn_count, 24);
    assert_eq!(aggregate.spawn_budget_limit, 20);
    assert_eq!(aggregate.spawn_budget_consumed_count, 12);
    assert!((aggregate.spawn_budget_utilization() - 0.6).abs() < 0.0001);
    assert_eq!(aggregate.spawn_budget_limited_count, 4);
    assert_eq!(aggregate.dropped_spawn_count(), 9);
    assert_eq!(
        aggregate.runtime_pressure_level,
        ParticleRuntimePressureLevel::Critical
    );
    assert_eq!(
        aggregate
            .emitter_stats_for(Some(11))
            .expect("entity 11 stats")
            .live_particle_budget_limit(),
        50
    );
    let mut gpu_readback = ParticleSimulationEventApplyReport::empty();
    gpu_readback.gpu_alive_particle_count = 300;
    gpu_readback.gpu_expired_particle_count = 6;
    gpu_readback.gpu_collision_event_count = 2;
    gpu_readback.gpu_spawned_particle_count = 7;
    gpu_readback.gpu_dropped_spawn_count = 4;
    gpu_readback.gpu_compacted_particle_count = 296;
    let gpu_merged = aggregate.merging_gpu_readback(&gpu_readback);
    assert_eq!(
        gpu_merged.live_particle_count,
        aggregate.live_particle_count
    );
    assert_eq!(gpu_merged.gpu_alive_particle_count, 300);
    assert_eq!(gpu_merged.gpu_expired_particle_count, 6);
    assert_eq!(gpu_merged.gpu_collision_event_count, 2);
    assert_eq!(gpu_merged.gpu_spawned_particle_count, 7);
    assert_eq!(gpu_merged.gpu_dropped_spawn_count, 4);
    assert_eq!(gpu_merged.gpu_compacted_particle_count, 296);
    assert_eq!(gpu_merged.dropped_spawn_count(), 13);
    assert_eq!(
        gpu_merged.runtime_pressure_level,
        ParticleRuntimePressureLevel::Critical
    );
    assert_eq!(event_report.dropped_spawn_count(), 9);
    assert!((event_report.spawn_budget_utilization() - 0.6).abs() < 0.0001);
}

/// Particle frame stats classify runtime pressure levels.
#[test]
fn particle_frame_stats_classify_runtime_pressure_levels() {
    let idle = frame_stats(|stats| {
        stats.max_particle_count = 100;
    });
    assert_eq!(
        idle.runtime_pressure_level(),
        ParticleRuntimePressureLevel::Idle
    );

    let nominal = frame_stats(|stats| {
        stats.live_particle_count = 25;
        stats.max_particle_count = 100;
        stats.live_particle_limit = 100;
    });
    assert_eq!(
        nominal.runtime_pressure_level(),
        ParticleRuntimePressureLevel::Nominal
    );

    let warning = frame_stats(|stats| {
        stats.live_particle_count = 90;
        stats.max_particle_count = 100;
        stats.live_particle_limit = 100;
    });
    assert_eq!(
        warning.runtime_pressure_level(),
        ParticleRuntimePressureLevel::Warning
    );

    let over_budget = frame_stats(|stats| {
        stats.live_particle_count = 100;
        stats.max_particle_count = 100;
        stats.live_particle_limit = 100;
    });
    assert_eq!(
        over_budget.runtime_pressure_level(),
        ParticleRuntimePressureLevel::Critical
    );

    let dropped = frame_stats(|stats| {
        stats.live_particle_count = 10;
        stats.max_particle_count = 100;
        stats.live_particle_limit = 100;
        stats.capacity_limited_spawn_count = 1;
    });
    assert_eq!(
        dropped.runtime_pressure_level(),
        ParticleRuntimePressureLevel::Critical
    );

    let aggregate = ParticleFrameStatsResource::new(
        0.0,
        vec![nominal, warning],
        BTreeMap::new(),
        0,
        0,
        0,
        0,
        0,
        0,
    );
    assert_eq!(
        aggregate.runtime_pressure_level,
        ParticleRuntimePressureLevel::Warning
    );
}

/// Noise force deterministically accelerates particles.
#[test]
fn noise_force() {
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 0.0;
        settings.appearance.lifetime = 10.0;
        settings.velocity.start_velocity = Float3::ZERO;
        settings.forces.gravity = Float3::ZERO;
        settings.forces.noise_strength = 2.0;
        settings.forces.noise_scale = 1.0;
        settings.forces.noise_speed = 0.0;
        settings.emission.seed = 0;
    });
    emitter.emit(1, None);
    advance(&mut emitter, 1.0);

    let particle = emitter.particles()[0];
    let expected = Float3::new(
        0.0,
        (2.17f64).sin() as f32 * 2.0,
        (4.31f64).sin() as f32 * 2.0,
    );
    assert!(simd_length(particle.velocity - expected) < 1e-4);
    assert!(simd_length(particle.position - expected) < 1e-4);
}

/// `SceneRuntime.advance_particles` steps every emitter component.
#[test]
fn scene_advances_all_emitters() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let a = scene.create_entity();
    let b = scene.create_entity();
    let mut emitter = emitter_with(|settings| {
        settings.emission.emission_rate = 10.0;
        settings.emission.max_particles = 100;
        settings.appearance.lifetime = 1000.0;
        settings.forces.gravity = Float3::ZERO;
    });
    emitter.emit(2, None);
    let _ = scene.set_component(emitter.clone(), a);
    let _ = scene.set_component(emitter, b);

    let stepped = scene.advance_particles(0.1, ParticleAdvanceOptions::default());
    assert_eq!(stepped, 2);
    // 2 seeded + 1 emitted
    assert_eq!(
        scene
            .component::<ParticleEmitter>(a)
            .expect("emitter a")
            .alive_count(),
        3
    );
    assert_eq!(
        scene
            .component::<ParticleEmitter>(b)
            .expect("emitter b")
            .alive_count(),
        3
    );
}

/// `SceneRuntime.emit_particles` triggers one emitter.
#[test]
fn scene_emit_particles() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let emitter_entity = scene.create_entity();
    let empty_entity = scene.create_entity();
    let _ = scene.set_component(
        emitter_with(|settings| {
            settings.emission.emission_rate = 0.0;
            settings.emission.max_particles = 5;
            settings.appearance.lifetime = 10.0;
            settings.forces.gravity = Float3::ZERO;
        }),
        emitter_entity,
    );

    let emitted = scene.emit_particles(emitter_entity, 3);
    assert!(emitted);
    assert_eq!(
        scene
            .component::<ParticleEmitter>(emitter_entity)
            .expect("particle emitter")
            .alive_count(),
        3
    );
    let missing_emitter_emitted = scene.emit_particles(empty_entity, 3);
    assert!(!missing_emitter_emitted);
}
