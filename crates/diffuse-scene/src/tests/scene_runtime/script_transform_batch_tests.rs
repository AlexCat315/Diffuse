//! Ported from `Engine/Tests/SceneRuntimeTests/ScriptTransformBatchTests.swift`.
//!
//! Swift built the phase context from exclusive inout pointers; the Rust context
//! borrows the same two values directly, so the test is a straight transcription.

use diffuse_math::simd::simd_compat::Float3;

use crate::physics::backend::null_physics_backend::NullPhysicsBackend;
use crate::physics::backend::physics_query_scene::PhysicsQueryScene;
use crate::runtime_world::{LocalTransform, RuntimeWorld, WorldTransform};
use crate::scheduling::schedule_commands::RuntimeCommandBuffer;
use crate::scripting::RuntimeScriptPhaseContext;

#[test]
fn local_writes_batch_until_a_world_space_read_including_generic_component_reads() {
    let mut world = RuntimeWorld::default();
    let parent = world.create_entity();
    let child = world.create_entity();
    assert!(world.set_parent(Some(parent), child));
    world.propagate_transforms_default();
    let mut commands = RuntimeCommandBuffer::default();

    let mut context = RuntimeScriptPhaseContext::with_physics_query_scene(
        &mut world,
        &mut commands,
        1.0 / 60.0,
        PhysicsQueryScene::new(Box::new(NullPhysicsBackend)),
    );

    for x in 1..=32 {
        assert!(context.set_local_transform(
            LocalTransform::from_translation_rotation_scale(
                Float3::new(x as f32, 0.0, 0.0),
                Default::default(),
                Float3::new(1.0, 1.0, 1.0),
            ),
            parent,
        ));
        assert!(context.hierarchy_needs_propagation());
    }
    assert!(context.translate(Float3::new(0.0, 2.0, 0.0), child));
    assert_eq!(
        context.local_transform(child).map(|t| t.translation()),
        Some(Float3::new(0.0, 2.0, 0.0))
    );
    assert!(context.hierarchy_needs_propagation());
    assert_eq!(
        context.world_transform(child).map(|t| t.translation()),
        Some(Float3::new(32.0, 2.0, 0.0))
    );
    assert!(!context.hierarchy_needs_propagation());
    assert!(context.translate(Float3::new(1.0, 0.0, 0.0), parent));
    let derived = context
        .component::<WorldTransform>(child)
        .expect("child has a derived world transform");
    assert_eq!(derived.translation(), Float3::new(33.0, 2.0, 0.0));
    assert!(!context.hierarchy_needs_propagation());
}
