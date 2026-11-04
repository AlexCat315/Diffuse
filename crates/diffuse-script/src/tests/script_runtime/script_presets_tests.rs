//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptPresetsTests.swift`.
//!
//! Swift's `LocalTransform(matrix: matrix_identity_float4x4)` /
//! `LocalTransform(translation:)` are `LocalTransform::IDENTITY` and
//! `LocalTransform::from_translation`; `t.rotation.act(v)` is
//! `t.rotation().act(v)` because Rust exposes the quaternion as a method.
//! `matrix_identity_float4x4` is `MATRIX_IDENTITY_FLOAT4X4`.

use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_component::ScriptComponent;
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// `rotator applies angular velocity each frame`
#[test]
fn rotator_applies_angular_velocity() {
    let mut runtime = scene();
    let scripts = ScriptRuntime::new();
    let rot_script = scripts.register(
        Script::rotator(Float3::new(0.0, std::f32::consts::PI, 0.0)),
        None,
    );
    runtime.set_script_driver(Box::new(scripts));

    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::new(MATRIX_IDENTITY_FLOAT4X4), entity);
    runtime.set_component(ScriptComponent::from_scripts([rot_script]), entity);

    // Half second at pi rad/s around Y = 90 degrees. +90° Y rotation maps -Z to -X.
    runtime.tick(0.5, 0, Vec::new());

    let transform = runtime
        .local_transform(entity)
        .expect("the entity keeps a transform");
    let forward = transform.rotation().act(Float3::new(0.0, 0.0, -1.0));
    assert!((forward.x - (-1.0)).abs() < 0.01);
    assert!(forward.z.abs() < 0.01);
}

/// `oscillator moves entity sinusoidally along axis`
#[test]
fn oscillator_moves_sinusoidally() {
    let mut runtime = scene();
    let scripts = ScriptRuntime::new();
    let osc_script = scripts.register(
        Script::oscillator(Float3::new(0.0, 1.0, 0.0), 2.0, 1.0),
        None,
    );
    runtime.set_script_driver(Box::new(scripts));

    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 1.0, 0.0)),
        entity,
    );
    runtime.set_component(ScriptComponent::from_scripts([osc_script]), entity);

    // At t=0.25 (quarter period), sin(pi/2)=1, so offset = (0,2,0)
    runtime.tick(0.25, 0, Vec::new());
    let first = runtime
        .local_transform(entity)
        .expect("the entity keeps a transform");
    assert!((first.translation().y - 3.0).abs() < 0.01);

    // At t=0.75 (3/4 period), sin(3pi/2)=-1, offset = (0,-2,0)
    runtime.tick(0.5, 0, Vec::new());
    let second = runtime
        .local_transform(entity)
        .expect("the entity keeps a transform");
    assert!((second.translation().y - (-1.0)).abs() < 0.01);
}

/// `follower moves entity toward target`
#[test]
fn follower_moves_toward_target() {
    let mut runtime = scene();
    let scripts = ScriptRuntime::new();

    let target = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(10.0, 0.0, 0.0)),
        target,
    );

    let follower_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::ZERO),
        follower_entity,
    );

    let follow_script = scripts.register(Script::follower(target, 10.0, 0.05), None);
    runtime.set_component(
        ScriptComponent::from_scripts([follow_script]),
        follower_entity,
    );
    runtime.set_script_driver(Box::new(scripts));

    // After 0.5s at speed 10, should move 5 units toward target
    runtime.tick(0.5, 0, Vec::new());
    let transform = runtime
        .local_transform(follower_entity)
        .expect("the follower keeps a transform");
    assert!(transform.translation().x > 0.0);
    assert!(transform.translation().x < 10.0);
}

/// `follower stops at arrival radius`
#[test]
fn follower_stops_at_arrival_radius() {
    let mut runtime = scene();
    let scripts = ScriptRuntime::new();

    let target = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.02, 0.0, 0.0)),
        target,
    );

    let follower_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::ZERO),
        follower_entity,
    );

    let follow_script = scripts.register(Script::follower(target, 10.0, 0.1), None);
    runtime.set_component(
        ScriptComponent::from_scripts([follow_script]),
        follower_entity,
    );
    runtime.set_script_driver(Box::new(scripts));

    runtime.tick(1.0, 0, Vec::new());
    let transform = runtime
        .local_transform(follower_entity)
        .expect("the follower keeps a transform");
    // Should not have moved since within arrival radius
    assert_eq!(transform.translation().x, 0.0);
}

/// `lookAt rotates entity to face target`
#[test]
fn look_at_rotates_to_face_target() {
    let mut runtime = scene();
    let scripts = ScriptRuntime::new();

    let target = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 0.0, -5.0)),
        target,
    );

    let looker = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::new(MATRIX_IDENTITY_FLOAT4X4), looker);

    let look_script = scripts.register(
        Script::look_at_target(target, Float3::new(0.0, 0.0, -1.0)),
        None,
    );
    runtime.set_component(ScriptComponent::from_scripts([look_script]), looker);
    runtime.set_script_driver(Box::new(scripts));

    runtime.tick(0.1, 0, Vec::new());

    let transform = runtime
        .local_transform(looker)
        .expect("the looker keeps a transform");
    // Forward (-Z) should now point toward target at (0,0,-5)
    let forward = transform.rotation().act(Float3::new(0.0, 0.0, -1.0));
    assert!(forward.z < -0.99);
}

/// `destroyAfter removes entity after elapsed time`
#[test]
fn destroy_after_removes_entity() {
    let mut runtime = scene();
    let scripts = ScriptRuntime::new();

    let entity = runtime.create_entity();
    let destroy_script = scripts.register(Script::destroy_after(1.0), None);
    runtime.set_component(ScriptComponent::from_scripts([destroy_script]), entity);
    runtime.set_script_driver(Box::new(scripts));

    // Tick for less than lifetime — entity still alive
    runtime.tick(0.5, 0, Vec::new());
    assert!(runtime.contains(entity));

    // Tick past lifetime — script enqueues destroy
    runtime.tick(0.6, 0, Vec::new());
    // Third tick processes the enqueued destroy command
    runtime.tick(0.01, 0, Vec::new());
    assert!(!runtime.contains(entity));
}

/// `mover translates entity at constant velocity`
#[test]
fn mover_translates_entity() {
    let mut runtime = scene();
    let scripts = ScriptRuntime::new();

    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    let move_script = scripts.register(Script::mover(Float3::new(3.0, 0.0, 0.0)), None);
    runtime.set_component(ScriptComponent::from_scripts([move_script]), entity);
    runtime.set_script_driver(Box::new(scripts));

    runtime.tick(2.0, 0, Vec::new());

    let transform = runtime
        .local_transform(entity)
        .expect("the entity keeps a transform");
    assert!((transform.translation().x - 6.0).abs() < 0.01);
}
