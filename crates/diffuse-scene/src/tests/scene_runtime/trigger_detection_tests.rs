//! Ported from `Engine/Tests/SceneRuntimeTests/TriggerDetectionTests.swift`.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::queries::trigger_detection::TriggerFrameResource;
use crate::scene_runtime::SceneRuntime;

fn box_collider(half_extents: f32, is_trigger: bool, layer_id: u16, layer_mask: u16) -> Collider {
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::splat(half_extents),
        center: Float3::ZERO,
    });
    collider.is_trigger = is_trigger;
    collider.layer_id = layer_id;
    collider.layer_mask = layer_mask;
    collider
}

fn place(runtime: &mut SceneRuntime, translation: Float3) -> crate::entity_id::EntityID {
    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation_rotation_scale(
            translation,
            Default::default(),
            Float3::new(1.0, 1.0, 1.0),
        ),
        entity,
    );
    entity
}

use crate::runtime_world::LocalTransform;

#[test]
fn enter_fires_on_overlap() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let trigger = place(&mut runtime, Float3::ZERO);
    runtime.set_component(box_collider(2.0, true, 1, u16::MAX), trigger);

    let other = place(&mut runtime, Float3::new(0.0, 0.0, 10.0));
    runtime.set_component(box_collider(0.5, false, 2, u16::MAX), other);

    // First tick: other is far away — no trigger.
    runtime.tick(0.1, 0, Vec::new());
    let frame = runtime
        .resource::<TriggerFrameResource>()
        .expect("trigger frame published");
    assert!(frame.enters.is_empty());

    runtime.set_local_transform(
        LocalTransform::from_translation_rotation_scale(
            Float3::new(0.0, 0.0, 1.0),
            Default::default(),
            Float3::new(1.0, 1.0, 1.0),
        ),
        other,
    );
    runtime.tick(0.1, 1, Vec::new());

    let frame = runtime
        .resource::<TriggerFrameResource>()
        .expect("trigger frame published");
    assert_eq!(frame.enters.len(), 1);
    assert_eq!(frame.enters[0].trigger_entity, trigger);
    assert_eq!(frame.enters[0].other_entity, other);
}

#[test]
fn exit_fires_on_leave() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let trigger = place(&mut runtime, Float3::ZERO);
    runtime.set_component(box_collider(2.0, true, 1, u16::MAX), trigger);

    let other = place(&mut runtime, Float3::ZERO);
    runtime.set_component(box_collider(0.5, false, 2, u16::MAX), other);

    runtime.tick(0.1, 0, Vec::new());
    let frame = runtime
        .resource::<TriggerFrameResource>()
        .expect("trigger frame published");
    assert_eq!(frame.enters.len(), 1);

    runtime.set_local_transform(
        LocalTransform::from_translation_rotation_scale(
            Float3::new(0.0, 0.0, 10.0),
            Default::default(),
            Float3::new(1.0, 1.0, 1.0),
        ),
        other,
    );
    runtime.tick(0.1, 1, Vec::new());
    let frame = runtime
        .resource::<TriggerFrameResource>()
        .expect("trigger frame published");
    assert_eq!(frame.exits.len(), 1);
    assert_eq!(frame.exits[0].trigger_entity, trigger);
    assert_eq!(frame.exits[0].other_entity, other);
    assert!(frame.enters.is_empty());
}

#[test]
fn layer_mask_filters_overlaps() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    // Trigger only detects layer 1 (mask bit 0b0010).
    let trigger = place(&mut runtime, Float3::ZERO);
    runtime.set_component(box_collider(2.0, true, 0, 0b0010), trigger);

    // Other entity on layer 2 (bit 0b0100).
    let other = place(&mut runtime, Float3::ZERO);
    runtime.set_component(box_collider(0.5, false, 2, u16::MAX), other);

    runtime.tick(0.1, 0, Vec::new());
    let frame = runtime
        .resource::<TriggerFrameResource>()
        .expect("trigger frame published");
    assert!(frame.enters.is_empty());
}

#[test]
fn trigger_stays_active_while_overlapping() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let trigger = place(&mut runtime, Float3::ZERO);
    runtime.set_component(box_collider(2.0, true, 1, u16::MAX), trigger);

    let other = place(&mut runtime, Float3::ZERO);
    runtime.set_component(box_collider(0.5, false, 2, u16::MAX), other);

    runtime.tick(0.1, 0, Vec::new());
    // Second frame: still overlapping, no new enter events.
    runtime.tick(0.1, 1, Vec::new());

    let frame = runtime
        .resource::<TriggerFrameResource>()
        .expect("trigger frame published");
    assert!(frame.enters.is_empty());
    assert!(frame.exits.is_empty());
    assert_eq!(frame.active.len(), 1);
}

#[test]
fn multiple_triggers_detect_independently() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let trigger_a = place(&mut runtime, Float3::new(-3.0, 0.0, 0.0));
    runtime.set_component(box_collider(1.0, true, 1, u16::MAX), trigger_a);
    let trigger_b = place(&mut runtime, Float3::new(3.0, 0.0, 0.0));
    runtime.set_component(box_collider(1.0, true, 1, u16::MAX), trigger_b);

    let other = place(&mut runtime, Float3::new(-3.0, 0.0, 0.0));
    runtime.set_component(box_collider(0.5, false, 2, u16::MAX), other);

    runtime.tick(0.1, 0, Vec::new());
    let frame = runtime
        .resource::<TriggerFrameResource>()
        .expect("trigger frame published");
    assert_eq!(frame.enters.len(), 1);
    assert_eq!(frame.enters[0].trigger_entity, trigger_a);
    assert_eq!(frame.enters[0].other_entity, other);
}
