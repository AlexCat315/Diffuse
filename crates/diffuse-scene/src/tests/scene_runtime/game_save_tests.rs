//! Ported from `Engine/Tests/SceneRuntimeTests/GameSaveTests.swift`.
//!
//! Swift's `GameSave.capture(scene:state:metadata:)` is `capture_with_state` in
//! Rust and `capture(scene:metadata:)` is `capture`; the scene-only call passes
//! an empty metadata map where Swift relied on a default argument.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float3;
use serde::{Deserialize, Serialize};

use crate::components::core::registry::ComponentRegistry;
use crate::media::animation::AnimationPlayer;
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use crate::runtime_world::LocalTransform;
use crate::scene_bootstrap::SceneNameComponent;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::game_save::{GameSave, GameSaveError};
use crate::serialization::scene_serializer::SceneSerializer;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct PlayerProgress {
    score: i64,
    health: f32,
    inventory: Vec<String>,
    checkpoint: String,
}

fn make_scene() -> SceneRuntime {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let player = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Player"), player);
    scene.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 9.0)),
        player,
    );
    scene.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 70.0,
            ..RigidBodyOptions::default()
        }),
        player,
    );
    scene
}

/// Scene + game state round-trips through a single document.
#[test]
fn full_round_trip() {
    let scene = make_scene();
    let progress = PlayerProgress {
        score: 4200,
        health: 75.5,
        inventory: vec!["sword".to_string(), "key".to_string()],
        checkpoint: "level-2".to_string(),
    };
    let metadata = BTreeMap::from([
        ("savedAt".to_string(), "2026-05-29".to_string()),
        ("slot".to_string(), "1".to_string()),
    ]);

    let save = GameSave::capture_with_state(&scene, &progress, metadata).expect("capture save");
    let document = save.serialized().expect("serialized");
    assert!(!document.is_empty());

    let loaded = GameSave::load(&document).expect("load save");
    assert_eq!(loaded.metadata.get("slot").map(String::as_str), Some("1"));

    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    loaded.restore_scene(&mut restored).expect("restore scene");
    let player = restored.find_entity_named("Player").expect("player entity");
    let transform = restored.local_transform(player).expect("player transform");
    assert!((transform.translation().x - 4.0).abs() < 0.01);
    assert!((transform.translation().z - 9.0).abs() < 0.01);
    assert_eq!(
        restored
            .component::<RigidBody>(player)
            .map(|body| body.mass),
        Some(70.0)
    );

    let decoded: Option<PlayerProgress> = loaded.decode_state().expect("decode state");
    assert_eq!(decoded, Some(progress));
}

/// Scene-only save carries no state payload.
#[test]
fn scene_only() {
    let save = GameSave::capture(&make_scene(), BTreeMap::new()).expect("capture save");
    let loaded = GameSave::load(&save.serialized().expect("serialized")).expect("load save");
    assert!(loaded.state.is_none());
    let decoded: Option<PlayerProgress> = loaded.decode_state().expect("decode state");
    assert_eq!(decoded, None);

    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    loaded.restore_scene(&mut restored).expect("restore scene");
    assert_eq!(restored.snapshot().entity_count, 1);
}

/// Captures live runtime transforms, not just the authored layout.
#[test]
fn captures_runtime_state() {
    let mut scene = make_scene();
    let player = scene.find_entity_named("Player").expect("player entity");
    // Simulate the player moving during play.
    scene.set_local_transform(
        LocalTransform::from_translation(Float3::new(100.0, 0.0, -50.0)),
        player,
    );

    let save = GameSave::capture(&scene, BTreeMap::new()).expect("capture save");
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    GameSave::load(&save.serialized().expect("serialized"))
        .expect("load save")
        .restore_scene(&mut restored)
        .expect("restore scene");

    let transform = restored
        .local_transform(
            restored
                .find_entity_named("Player")
                .expect("restored player entity"),
        )
        .expect("restored player transform");
    assert!((transform.translation().x - 100.0).abs() < 0.01);
    assert!((transform.translation().z + 50.0).abs() < 0.01);
}

/// Rejects an unsupported version.
#[test]
fn unsupported_version() {
    let error =
        GameSave::load(r#"{"version": 999, "scene": {"entities": []}}"#).expect_err("version");
    assert_eq!(error, GameSaveError::UnsupportedVersion(999));
}

/// Rejects a malformed document.
#[test]
fn malformed_document() {
    let error = GameSave::load("not a save").expect_err("malformed document");
    assert_eq!(error, GameSaveError::InvalidFormat);
}

/// `AnimationPlayer` playback time survives serialization.
#[test]
fn animation_time_persists() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    scene.set_component(
        AnimationPlayer::new(Some("run".to_string()), 1.0, true, true, 1.75),
        entity,
    );

    let data = SceneSerializer::serialize(scene.world()).expect("serialize");
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let player = restored
        .component::<AnimationPlayer>(restored.entities()[0])
        .expect("animation player");
    assert!((player.time - 1.75).abs() < 1e-6);
}
