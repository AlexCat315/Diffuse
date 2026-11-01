//! Ported from `Engine/Tests/SceneRuntimeTests/RagdollTests.swift`.
//!
//! Swift's `tick(deltaTime:)` has no frame index, so every call here advances one
//! and supplies no input events. Swift indexes matrices with `.columns.3`; the Rust
//! type stores columns in an array, so the same column is `columns[3]`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4};

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::media::animation::{JointPalette, JointPaletteMap};
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::ragdoll::{Ragdoll, RagdollBoneMapping, RagdollMode};
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use crate::runtime_world::LocalTransform;
use crate::scene_bootstrap::SceneNameComponent;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

const DELTA_TIME: f64 = 1.0 / 60.0;

/// Swift's `translationMatrix(_:)`: identity basis with the value in column 3.
fn translation_matrix(value: Float3) -> Float4x4 {
    let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
    matrix.columns[3] = Float4::new(value.x, value.y, value.z, 1.0);
    matrix
}

fn palette_for(root: EntityID, matrices: Vec<Float4x4>) -> JointPaletteMap {
    JointPaletteMap::new(BTreeMap::from([(root, JointPalette::new(matrices))]))
}

/// `runtime.resource(JointPaletteMap.self)?.palettes[root]?.matrices[0].columns.3.x ?? 0`.
fn palette_translation_x(runtime: &SceneRuntime, root: EntityID) -> f32 {
    runtime
        .resource::<JointPaletteMap>()
        .and_then(|map| map.palettes.get(&root).cloned())
        .and_then(|palette| palette.matrices.first().map(|matrix| matrix.columns[3].x))
        .unwrap_or(0.0)
}

/// `runtime.ragdollStateFrame.states[root]?.bones.first?.isSimulated`.
fn bone_is_simulated(runtime: &SceneRuntime, root: EntityID) -> Option<bool> {
    runtime
        .ragdoll_state_frame()
        .states
        .get(&root)
        .and_then(|state| state.bones.first())
        .map(|bone| bone.is_simulated)
}

/// Animation, simulation, blending and partial-body modes share one mapping.
#[test]
fn runtime_modes() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::Natsel,
        gravity: Float3::ZERO,
        fixed_time_step_seconds: DELTA_TIME,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        ..PhysicsSettingsResource::default()
    });

    let root = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, root);
    let body = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, body);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            gravity_scale: 0.0,
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        body,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.2,
            center: Float3::ZERO,
        }),
        body,
    );
    runtime.set_component(
        Ragdoll::new(
            RagdollMode::Animated,
            1.0,
            true,
            vec![RagdollBoneMapping::new("hips", 0, body)],
        ),
        root,
    );

    runtime.set_resource(palette_for(
        root,
        vec![translation_matrix(Float3::new(0.0, 2.0, 0.0))],
    ));
    let _ = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        runtime
            .component::<RigidBody>(body)
            .map(|rigid_body| rigid_body.motion_type),
        Some(RigidBodyMotionType::Kinematic)
    );
    let animation_y = runtime
        .world_transform(body)
        .map(|transform| transform.translation().y)
        .unwrap_or(0.0);
    assert!((animation_y - 2.0).abs() < 0.001);
    assert_eq!(bone_is_simulated(&runtime, root), Some(false));

    let _ = runtime.set_ragdoll_mode(RagdollMode::Simulated, root, None);
    runtime.update_component::<RigidBody>(body, |rigid_body| {
        rigid_body.linear_velocity = Float3::new(1.0, 0.0, 0.0);
    });
    let _ = runtime.tick(DELTA_TIME, 1, Vec::new());
    assert_eq!(
        runtime
            .component::<RigidBody>(body)
            .map(|rigid_body| rigid_body.motion_type),
        Some(RigidBodyMotionType::Dynamic)
    );
    assert_eq!(bone_is_simulated(&runtime, root), Some(true));
    let simulated_x = runtime
        .world_transform(body)
        .map(|transform| transform.translation().x)
        .unwrap_or(0.0);
    assert!(simulated_x > 0.0);
    assert!((palette_translation_x(&runtime, root) - simulated_x).abs() < 0.001);

    let _ = runtime.set_ragdoll_mode(RagdollMode::Blended, root, Some(0.5));
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 2.0, 0.0)),
        body,
    );
    runtime.update_component::<RigidBody>(body, |rigid_body| {
        rigid_body.linear_velocity = Float3::ZERO;
    });
    runtime.set_resource(palette_for(root, vec![MATRIX_IDENTITY_FLOAT4X4]));
    let _ = runtime.tick(DELTA_TIME, 2, Vec::new());
    let blended_x = palette_translation_x(&runtime, root);
    assert!((blended_x - 1.0).abs() < 0.02);

    let disabled_bone = runtime.set_ragdoll_bone_simulation(false, 0, root);
    assert!(disabled_bone);
    let _ = runtime.set_ragdoll_mode(RagdollMode::Simulated, root, None);
    runtime.set_resource(palette_for(
        root,
        vec![translation_matrix(Float3::new(0.0, 4.0, 0.0))],
    ));
    let _ = runtime.tick(DELTA_TIME, 3, Vec::new());
    assert_eq!(
        runtime
            .component::<RigidBody>(body)
            .map(|rigid_body| rigid_body.motion_type),
        Some(RigidBodyMotionType::Kinematic)
    );
    let disabled_y = runtime
        .world_transform(body)
        .map(|transform| transform.translation().y)
        .unwrap_or(0.0);
    assert!((disabled_y - 4.0).abs() < 0.001);
}

/// Scene v2 remaps ragdoll body and joint entities.
#[test]
fn serialization_round_trip() {
    let mut original = SceneRuntime::new(ComponentRegistry::built_in());
    let root = original.create_entity();
    original.set_component(SceneNameComponent::new("root"), root);
    let body = original.create_entity();
    original.set_component(SceneNameComponent::new("body"), body);
    let joint = original.create_entity();
    original.set_component(SceneNameComponent::new("joint"), joint);
    let offset = translation_matrix(Float3::new(0.0, 0.5, 0.0));
    original.set_component(
        Ragdoll::new(
            RagdollMode::Blended,
            0.35,
            true,
            vec![RagdollBoneMapping::with_mapping(
                "spine",
                3,
                body,
                Some(joint),
                offset,
                RigidBodyMotionType::Dynamic,
                false,
                0.8,
            )],
        ),
        root,
    );

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let restored_root = restored.find_entity_named("root").expect("root");
    let restored_body = restored.find_entity_named("body").expect("body");
    let restored_joint = restored.find_entity_named("joint").expect("joint");
    let ragdoll = restored
        .component::<Ragdoll>(restored_root)
        .expect("ragdoll");
    assert_eq!(ragdoll.mode, RagdollMode::Blended);
    assert_eq!(ragdoll.blend_weight, 0.35);
    let bone = ragdoll.bones.first().expect("bone");
    assert_eq!(bone.body_entity, restored_body);
    assert_eq!(bone.joint_entity, Some(restored_joint));
    assert_eq!(bone.body_from_palette, offset);
    assert!(!bone.is_simulation_enabled);
}
