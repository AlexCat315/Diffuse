//! Ported from `Engine/Tests/SceneRuntimeTests/ParticleSettingsTests.swift`.
//!
//! Swift's closure `init { … }` for `ParticleEmitterSettings`/`ParticleTextureSheetModule`
//! is `configured(…)` next to the Rust types; the emitter still normalizes on construction.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::particles::particle_modules::{
    ParticleEmitterModuleSettings, ParticleTextureSheetModule,
};
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

/// Missing groups and fields use the defaults of their owners.
#[test]
fn missing_settings_defaults() {
    let settings: ParticleEmitterSettings =
        serde_json::from_str(r#"{"emission":{"emissionRate":12}}"#).expect("decode settings");
    let mut expected = ParticleEmitterSettings::default();
    expected.emission.emission_rate = 12.0;
    assert_eq!(settings, expected);
}

/// Configuration validates the owning groups before starting a simulation.
#[test]
fn grouped_validation() {
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.emission_rate = -10.0;
    settings.shape.spawn_radius = -2.0;
    settings.forces.noise_scale = 0.0;
    settings.collision.collision_restitution = 3.0;
    settings.trails.ribbon_smoothing_segments = 100;
    settings.gpu_simulation.workgroup_size = 0;

    let emitter = ParticleEmitter::new(settings);
    assert_eq!(emitter.settings.emission.emission_rate, 0.0);
    assert_eq!(emitter.settings.shape.spawn_radius, 0.0);
    assert_eq!(emitter.settings.forces.noise_scale, 0.0001);
    assert_eq!(emitter.settings.collision.collision_restitution, 1.0);
    assert_eq!(emitter.settings.trails.ribbon_smoothing_segments, 16);
    assert_eq!(emitter.settings.gpu_simulation.workgroup_size, 1);
    assert!(emitter.particles().is_empty());
}

/// Scene records store grouped settings and preserve all seed bits and optional
/// assets.
#[test]
fn grouped_scene_round_trip() {
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.seed = u64::MAX;
    settings.shape.origin_offset = Float3::new(1.0, 2.0, 3.0);
    settings.texture_sheet.texture_asset_id = Some("Textures/fire.png".to_string());
    settings.texture_sheet.texture_path = Some("/tmp/fire.png".to_string());
    settings.texture_sheet.columns = 4;
    settings.texture_sheet.frame_count = 4;
    settings.forces.gravity = Float3::new(0.0, -2.0, 0.0);

    let emitter = ParticleEmitter::new(settings);
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    scene.set_component(emitter.clone(), entity);

    let data = SceneSerializer::serialize(scene.world()).expect("serialize");
    let value: serde_json::Value = serde_json::from_str(&data).expect("decode scene");
    let entities = value["entities"].as_array().expect("entities");
    let components = entities[0]["components"].as_object().expect("components");
    let record = components["particleEmitter"]
        .as_object()
        .expect("particle emitter record");
    assert!(record["settings"].is_object());
    assert!(record.get("emissionRate").is_none());
    assert!(record.get("seed").is_none());

    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let restored_entity = restored.entities()[0];
    let result = restored
        .component::<ParticleEmitter>(restored_entity)
        .expect("particle emitter");
    assert_eq!(result.settings, emitter.settings);
}

/// Module application copies the whole group, including values not edited by
/// the inspector.
#[test]
fn whole_module_application() {
    let mut emitter = ParticleEmitter::default();
    let mut stack = emitter.module_stack();
    let index = stack
        .modules
        .iter()
        .position(|module| module.id == "textureSheet")
        .expect("texture sheet module");
    let texture = ParticleTextureSheetModule::configured(|module| {
        module.texture_asset_id = Some("smoke.png".to_string());
        module.columns = 8;
        module.frame_count = 8;
        module.start_frame = 3;
    });
    stack.modules[index].settings = ParticleEmitterModuleSettings::TextureSheet(texture.clone());
    emitter.apply(stack);
    assert_eq!(emitter.settings.texture_sheet, texture);
}
