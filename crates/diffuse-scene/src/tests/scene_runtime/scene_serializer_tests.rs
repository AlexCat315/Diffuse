//! Ported from `Engine/Tests/SceneRuntimeTests/SceneSerializerTests.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};

use crate::components::core::registry::ComponentRegistry;
use crate::media::animation::{
    AnimationBlendSample1D, AnimationBlendSpace1D, AnimationGraph, AnimationGraphPlayer,
    AnimationMotion, AnimationState, AnimationStateMachine, AnimationTransition,
    AnimationTransitionComparison,
};
use crate::media::audio::{AudioListener, AudioSource};
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::particles::particle_curve::{ParticleCurve, ParticleCurveKeyframe};
use crate::particles::particle_events::ParticleSubEmitter;
use crate::particles::particle_gpu_simulation_plan::{
    ParticleGPUSimulationPlan, ParticleGPUSimulationPlanStatus,
};
use crate::particles::particle_modules::{
    ParticleAppearanceModule, ParticleCollisionModule, ParticleEmissionModule,
    ParticleEmitterModuleSettings, ParticleForcesModule, ParticleGPUSimulationModule,
    ParticleModuleStack, ParticleRendererModule, ParticleSubEmittersModule,
    ParticleTextureSheetModule, ParticleTrailsModule, ParticleVelocityModule,
};
use crate::particles::particle_types::{
    ParticleBlendMode, ParticleCollisionMode, ParticleEmissionShape, ParticleForceMode,
    ParticleRenderAlignment, ParticleRenderBoundsMode, ParticleRenderMode,
    ParticleSimulationBackend, ParticleSimulationSpace, ParticleSortMode,
    ParticleSubEmitterTrigger, ParticleTextureSheetPlaybackMode, ParticleVectorFieldMode,
};
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::joints::physics_joint::PhysicsJoint;
use crate::physics::joints::physics_joint_configuration::{
    PhysicsJointConfiguration, PhysicsJointMotor, PhysicsJointMotorMode, PhysicsJointSpring,
    SixDofJointConfiguration,
};
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use crate::rendering::render_extraction::{
    CameraComponent, LightComponent, LightType, RenderMaterialComponent, RenderMeshComponent,
};
use crate::runtime_world::LocalTransform;
use crate::scene_bootstrap::{AssetReferenceComponent, SceneKindComponent, SceneNameComponent};
use crate::scene_graph::prefab::Prefab;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

fn runtime() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn translation_matrix(translation: Float3) -> Float4x4 {
    Float4x4::from_columns([
        Float4::new(1.0, 0.0, 0.0, 0.0),
        Float4::new(0.0, 1.0, 0.0, 0.0),
        Float4::new(0.0, 0.0, 1.0, 0.0),
        Float4::new(translation.x, translation.y, translation.z, 1.0),
    ])
}

fn roundtrip(source: &SceneRuntime) -> SceneRuntime {
    let data = SceneSerializer::serialize(source.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    restored
}

/// Round-trip: empty scene.
#[test]
fn empty_scene_round_trip() {
    let original = runtime();
    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    assert!(!data.is_empty());

    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    assert_eq!(restored.snapshot().entity_count, 0);
}

/// Round-trip: entity with name and transform.
#[test]
fn entity_with_name_and_transform() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_component(SceneNameComponent::new("TestEntity"), entity);
    original.set_local_transform(
        LocalTransform::new(translation_matrix(Float3::new(3.0, 5.0, 7.0))),
        entity,
    );

    let restored = roundtrip(&original);

    assert_eq!(restored.snapshot().entity_count, 1);
    let entities = restored.entities();
    assert_eq!(entities.len(), 1);
    let name = restored.component::<SceneNameComponent>(entities[0]);
    assert_eq!(name.map(|name| name.value), Some("TestEntity".to_string()));
    let transform = restored.local_transform(entities[0]).expect("transform");
    assert!((transform.matrix.columns[3].x - 3.0).abs() < 0.01);
    assert!((transform.matrix.columns[3].y - 5.0).abs() < 0.01);
    assert!((transform.matrix.columns[3].z - 7.0).abs() < 0.01);
}

/// Round-trip: parent-child hierarchy.
#[test]
fn parent_child_hierarchy() {
    let mut original = runtime();
    let parent = original.create_entity();
    original.set_component(SceneNameComponent::new("Parent"), parent);
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), parent);

    let child = original.create_entity();
    original.set_component(SceneNameComponent::new("Child"), child);
    original.set_local_transform(
        LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
        child,
    );
    original.set_parent(Some(parent), child);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    restored.tick(0.0, 0, Vec::new());

    assert_eq!(restored.entities().len(), 2);
    let restored_parent = restored.find_entity_named("Parent").expect("parent");
    let restored_child = restored.find_entity_named("Child").expect("child");
    assert_eq!(restored.parent(restored_child), Some(restored_parent));
}

/// Round-trip: rigid body preserves properties.
#[test]
fn rigid_body_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    let body = RigidBody::new(RigidBodyOptions {
        motion_type: RigidBodyMotionType::Dynamic,
        mass: 80.0,
        linear_velocity: Float3::new(1.0, 2.0, 3.0),
        angular_velocity: Float3::new(4.0, 5.0, 6.0),
        accumulated_force: Float3::new(7.0, 8.0, 9.0),
        accumulated_torque: Float3::new(10.0, 11.0, 12.0),
        accumulated_linear_impulse: Float3::new(13.0, 14.0, 15.0),
        accumulated_angular_impulse: Float3::new(16.0, 17.0, 18.0),
        gravity_scale: 2.0,
        linear_damping: 0.1,
        allow_sleep: false,
        is_sleeping: true,
        continuous_collision_detection: true,
        ..RigidBodyOptions::default()
    });
    original.set_component(body.clone(), entity);

    let restored = roundtrip(&original);
    let entities = restored.entities();
    assert_eq!(entities.len(), 1);
    let rb = restored
        .component::<RigidBody>(entities[0])
        .expect("rigid body");
    assert_eq!(rb.motion_type, RigidBodyMotionType::Dynamic);
    assert_eq!(rb.mass, 80.0);
    assert_eq!(rb.gravity_scale, 2.0);
    assert_eq!(rb.linear_damping, 0.1);
    assert!(!rb.allow_sleep);
    assert!(rb.continuous_collision_detection);
    assert_eq!(rb, body);
}

/// Round-trip: native character controller.
#[test]
fn character_controller_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    let controller = CharacterController::new(
        0.35,
        0.7,
        0.3,
        Float3::new(0.1, 0.2, 0.3),
        42.0,
        0.25,
        0.015,
        82.0,
        640.0,
        1.25,
        3,
        0x00FF,
    );
    original.set_component(controller.clone(), entity);

    let restored = roundtrip(&original);
    let restored_entity = restored.entities()[0];
    assert_eq!(
        restored.component::<CharacterController>(restored_entity),
        Some(controller)
    );
}

/// Round-trip: box collider.
#[test]
fn box_collider_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(1.0, 2.0, 3.0),
        center: Float3::new(0.0, 0.5, 0.0),
    });
    collider.is_trigger = true;
    collider.layer_id = 3;
    collider.layer_mask = 0x00FF;
    original.set_component(collider, entity);

    let restored = roundtrip(&original);
    let col = restored
        .component::<Collider>(restored.entities()[0])
        .expect("collider");
    assert!(col.is_trigger);
    assert_eq!(col.layer_id, 3);
    assert_eq!(col.layer_mask, 0x00FF);
    match col.shape() {
        ColliderShape::Box {
            half_extents,
            center,
        } => {
            assert_eq!(half_extents, Float3::new(1.0, 2.0, 3.0));
            assert_eq!(center, Float3::new(0.0, 0.5, 0.0));
        }
        other => panic!("expected box shape, got {other:?}"),
    }
}

/// Round-trip: sphere collider.
#[test]
fn sphere_collider_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    original.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 2.5,
            center: Float3::new(0.0, 1.0, 0.0),
        }),
        entity,
    );

    let restored = roundtrip(&original);
    let col = restored
        .component::<Collider>(restored.entities()[0])
        .expect("collider");
    match col.shape() {
        ColliderShape::Sphere { radius, center } => {
            assert_eq!(radius, 2.5);
            assert_eq!(center, Float3::new(0.0, 1.0, 0.0));
        }
        other => panic!("expected sphere shape, got {other:?}"),
    }
}

/// Round-trip: camera component.
#[test]
fn camera_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    original.set_component(
        CameraComponent::new(
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            1.2,
            1.777,
            0.05,
            500.0,
            true,
        ),
        entity,
    );

    let restored = roundtrip(&original);
    let cam = restored
        .component::<CameraComponent>(restored.entities()[0])
        .expect("camera");
    assert!(cam.is_active);
    assert_eq!(cam.fov_y_radians, 1.2);
    assert_eq!(cam.aspect_ratio, 1.777);
    assert_eq!(cam.near, 0.05);
    assert_eq!(cam.far, 500.0);
}

/// Round-trip: light component.
#[test]
fn light_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    original.set_component(
        LightComponent::new(
            LightType::Spot,
            Float3::new(1.0, 0.5, 0.2),
            5.0,
            25.0,
            15.0,
            40.0,
            true,
        ),
        entity,
    );

    let restored = roundtrip(&original);
    let light = restored
        .component::<LightComponent>(restored.entities()[0])
        .expect("light");
    assert_eq!(light.light_type, LightType::Spot);
    assert_eq!(light.intensity, 5.0);
    assert_eq!(light.range, 25.0);
    assert!(light.cast_shadows);
}

/// Round-trip: audio source and listener.
#[test]
fn audio_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    original.set_component(
        AudioSource::new("footstep", 0.8, 1.2, true, false, 0.5),
        entity,
    );
    original.set_component(AudioListener::new(0.9), entity);

    let restored = roundtrip(&original);
    let entities = restored.entities();
    let source = restored
        .component::<AudioSource>(entities[0])
        .expect("audio source");
    assert_eq!(source.clip_name, "footstep");
    assert_eq!(source.volume, 0.8);
    assert!(source.loop_);
    let listener = restored
        .component::<AudioListener>(entities[0])
        .expect("audio listener");
    assert_eq!(listener.master_volume, 0.9);
}

/// Round-trip: animation graph player.
#[test]
fn animation_graph_player_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    let graph = AnimationGraph::new(
        vec![AnimationBlendSpace1D::new(
            "locomotion",
            "speed",
            vec![
                AnimationBlendSample1D::new(Some("idle".to_string()), 0.0),
                AnimationBlendSample1D::new(Some("run".to_string()), 1.0),
            ],
        )],
        AnimationStateMachine::new(
            "Idle",
            vec![
                AnimationState::new(
                    "Idle",
                    AnimationMotion::Clip(Some("idle".to_string())),
                    1.0,
                    true,
                ),
                AnimationState::new(
                    "Run",
                    AnimationMotion::BlendSpace1D("locomotion".to_string()),
                    1.25,
                    true,
                ),
            ],
            vec![AnimationTransition::new(
                "Idle",
                "Run",
                "speed",
                AnimationTransitionComparison::GreaterThan,
                0.5,
                0.2,
            )],
        ),
    );
    original.set_component(
        AnimationGraphPlayer::new(
            graph,
            BTreeMap::from([("speed".to_string(), 0.75)]),
            Some("Run".to_string()),
            Some("Idle".to_string()),
            0.4,
            1.2,
            0.1,
            0.2,
            1.5,
            false,
        ),
        entity,
    );

    let restored = roundtrip(&original);
    let player = restored
        .component::<AnimationGraphPlayer>(restored.entities()[0])
        .expect("player");
    assert_eq!(player.graph.blend_spaces_1d[0].samples.len(), 2);
    assert_eq!(
        player.graph.state_machine.transitions[0].comparison,
        AnimationTransitionComparison::GreaterThan
    );
    assert_eq!(
        player.graph.state_machine.states[1].motion,
        AnimationMotion::BlendSpace1D("locomotion".to_string())
    );
    assert_eq!(player.parameters.get("speed"), Some(&0.75));
    assert_eq!(player.active_state.as_deref(), Some("Run"));
    assert_eq!(player.previous_state.as_deref(), Some("Idle"));
    assert!(!player.is_playing);
}

/// Round-trip: full scene with multiple entity types.
#[test]
fn full_scene_round_trip() {
    let mut original = runtime();

    let ground = original.create_entity();
    original.set_component(SceneNameComponent::new("Ground"), ground);
    original.set_component(SceneKindComponent::new("Static Mesh"), ground);
    original.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, -0.5, 0.0)),
        ground,
    );
    original.set_component(
        RenderMeshComponent::new(0, true, Float3::splat(1.0), None, Vec::new()),
        ground,
    );
    original.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::new(10.0, 0.5, 10.0),
            center: Float3::ZERO,
        }),
        ground,
    );
    original.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Static,
            ..RigidBodyOptions::default()
        }),
        ground,
    );

    let player = original.create_entity();
    original.set_component(SceneNameComponent::new("Player"), player);
    original.set_component(SceneKindComponent::new("Character"), player);
    original.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 1.0, 0.0)),
        player,
    );
    original.set_component(
        Collider::with_shape(ColliderShape::Capsule {
            radius: 0.5,
            half_height: 1.0,
            center: Float3::new(0.0, 1.0, 0.0),
        }),
        player,
    );
    original.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 80.0,
            ..RigidBodyOptions::default()
        }),
        player,
    );

    let camera = original.create_entity();
    original.set_component(SceneNameComponent::new("MainCamera"), camera);
    original.set_component(SceneKindComponent::new("Camera"), camera);
    original.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 5.0, 10.0)),
        camera,
    );
    original.set_component(
        CameraComponent {
            is_active: true,
            ..CameraComponent::default()
        },
        camera,
    );
    original.set_component(AudioListener::default(), camera);

    original.set_parent(Some(ground), player);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");

    assert_eq!(restored.snapshot().entity_count, 3);

    let ground2 = restored.find_entity_named("Ground").expect("ground");
    assert_eq!(
        restored
            .component::<RigidBody>(ground2)
            .map(|body| body.motion_type),
        Some(RigidBodyMotionType::Static)
    );
    assert_eq!(
        restored
            .component::<RenderMeshComponent>(ground2)
            .map(|mesh| mesh.mesh_index),
        Some(0)
    );

    let player2 = restored.find_entity_named("Player").expect("player");
    assert_eq!(
        restored
            .component::<RigidBody>(player2)
            .map(|body| body.mass),
        Some(80.0)
    );
    assert!(restored.component::<Collider>(player2).is_some());

    let camera2 = restored.find_entity_named("MainCamera").expect("camera");
    assert_eq!(
        restored
            .component::<CameraComponent>(camera2)
            .map(|camera| camera.is_active),
        Some(true)
    );
    assert!(restored.component::<AudioListener>(camera2).is_some());

    restored.tick(0.0, 0, Vec::new());
    assert_eq!(restored.parent(player2), Some(ground2));
}

/// Round-trip: render material (PBR factors + texture indices).
#[test]
fn render_material_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_component(
        RenderMaterialComponent::new(
            Float4::new(0.2, 0.4, 0.6, 1.0),
            Some(7),
            Some(9),
            0.8,
            0.3,
            Float3::new(1.0, 0.0, 0.0),
            None,
            None,
            None,
        ),
        entity,
    );

    let restored = roundtrip(&original);
    let material = restored
        .component::<RenderMaterialComponent>(restored.entities()[0])
        .expect("material");
    assert_eq!(material.base_color_factor, Float4::new(0.2, 0.4, 0.6, 1.0));
    assert_eq!(material.base_color_texture_index, Some(7));
    assert_eq!(material.normal_texture_index, Some(9));
    assert_eq!(material.metallic_factor, 0.8);
    assert_eq!(material.roughness_factor, 0.3);
    assert_eq!(material.emissive_factor, Float3::new(1.0, 0.0, 0.0));
}

/// Round-trip: asset reference.
#[test]
fn asset_reference_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    let reference = AssetReferenceComponent::new(
        "a1",
        "Barrel",
        "models/barrel.glb",
        "/proj/models/barrel.glb",
        "mesh",
        4,
    );
    original.set_component(reference.clone(), entity);

    let restored = roundtrip(&original);
    assert_eq!(
        restored.component::<AssetReferenceComponent>(restored.entities()[0]),
        Some(reference)
    );
}

fn module_ids(stack: &ParticleModuleStack) -> Vec<String> {
    stack
        .modules
        .iter()
        .map(|module| module.id.clone())
        .collect()
}

/// Round-trip: particle emitter configuration.
#[test]
fn particle_emitter_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    let sub_emitters = vec![
        ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::Death,
            2,
            0.5,
            1,
            0.2,
            0.4,
            Float3::new(2.0, 0.0, 0.0),
            Float3::new(0.1, 0.0, 0.0),
            0.3,
            0.1,
            Float4::new(1.0, 0.0, 0.0, 1.0),
            Float4::new(1.0, 0.0, 0.0, 0.0),
        ),
        ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::Collision,
            1,
            1.0,
            2,
            0.4,
            0.8,
            Float3::new(0.0, 2.0, 0.0),
            Float3::new(0.0, 0.2, 0.0),
            0.5,
            0.2,
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float4::new(0.0, 0.0, 1.0, 0.0),
        ),
    ];
    let settings = ParticleEmitterSettings {
        emission: ParticleEmissionModule::configured(|module| {
            module.looping = false;
            module.duration = 4.5;
            module.simulation_speed = 1.5;
            module.prewarm_time = 1.25;
            module.prewarm_step = 0.05;
            module.emission_rate = 33.0;
            module.emission_rate_curve = ParticleCurve::Constant(1.5);
            module.distance_emission_rate = 12.0;
            module.distance_emission_rate_curve = ParticleCurve::Keyframes(vec![
                ParticleCurveKeyframe::new(0.0, 0.0),
                ParticleCurveKeyframe::new(1.0, 2.0),
            ]);
            module.burst_count = 7;
            module.burst_interval = 0.25;
            module.max_particles = 128;
            module.max_spawned_particles_per_frame = 48;
            module.max_rendered_particles = 64;
            module.seed = 12_345;
        }),
        appearance: ParticleAppearanceModule::configured(|module| {
            module.lifetime = 1.5;
            module.start_size = 0.5;
            module.end_size = 0.1;
            module.size_randomness = 0.35;
            module.start_rotation = 0.25;
            module.rotation_randomness = 0.5;
            module.angular_velocity = 1.5;
            module.angular_velocity_randomness = 0.75;
            module.size_curve = ParticleCurve::Keyframes(vec![
                ParticleCurveKeyframe::new(0.0, 0.0),
                ParticleCurveKeyframe::new(0.5, 1.0),
                ParticleCurveKeyframe::new(1.0, 0.25),
            ]);
            module.color_curve = ParticleCurve::Keyframes(vec![
                ParticleCurveKeyframe::new(0.0, 1.0),
                ParticleCurveKeyframe::new(1.0, 0.0),
            ]);
            module.blend_mode = ParticleBlendMode::Additive;
        }),
        sub_emitters: ParticleSubEmittersModule::configured(|module| {
            module.legacy_trigger = ParticleSubEmitterTrigger::Collision;
            module.legacy_burst_count = 3;
            module.legacy_probability = 0.75;
            module.legacy_max_depth = 2;
            module.legacy_inherit_velocity = 0.5;
            module.legacy_lifetime = 0.35;
            module.legacy_start_velocity = Float3::new(1.0, 2.0, 3.0);
            module.legacy_velocity_randomness = Float3::new(0.1, 0.2, 0.3);
            module.legacy_start_size = 0.2;
            module.legacy_end_size = 0.05;
            module.legacy_start_color = Float4::new(1.0, 0.5, 0.25, 1.0);
            module.legacy_end_color = Float4::new(1.0, 0.25, 0.0, 0.0);
            module.rules = sub_emitters.clone();
        }),
        shape: crate::particles::particle_modules::ParticleShapeModule::configured(|module| {
            module.spawn_radius = 0.25;
            module.emission_shape = ParticleEmissionShape::Cone;
            module.box_half_extents = Float3::new(1.0, 2.0, 3.0);
            module.cone_radius = 0.75;
            module.cone_height = 2.5;
        }),
        velocity: ParticleVelocityModule::configured(|module| {
            module.start_velocity = Float3::new(0.0, 3.0, 0.0);
            module.velocity_inheritance = 0.4;
        }),
        forces: ParticleForcesModule::configured(|module| {
            module.gravity = Float3::new(0.0, -2.0, 0.0);
            module.noise_strength = 1.25;
            module.noise_scale = 3.5;
            module.noise_speed = 0.75;
            module.force_mode = ParticleForceMode::Vortex;
            module.force_center = Float3::new(1.0, 2.0, 3.0);
            module.force_axis = Float3::new(0.0, 1.0, 0.0);
            module.force_radius = 12.0;
            module.force_strength = 4.5;
            module.force_falloff = 2.0;
            module.vector_field_mode = ParticleVectorFieldMode::Curl;
            module.vector_field_direction = Float3::new(0.0, 0.0, 1.0);
            module.vector_field_strength = 6.25;
            module.vector_field_scale = 2.5;
            module.vector_field_scroll_speed = 0.4;
        }),
        collision: ParticleCollisionModule::configured(|module| {
            module.collision_mode = ParticleCollisionMode::WorldPlane;
            module.collision_plane_y = -1.0;
            module.collision_restitution = 0.7;
            module.collision_damping = 0.2;
        }),
        gpu_simulation: ParticleGPUSimulationModule::configured(|module| {
            module.simulation_space = ParticleSimulationSpace::World;
            module.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
            module.workgroup_size = 128;
        }),
        renderer: ParticleRendererModule::configured(|module| {
            module.render_mode = ParticleRenderMode::Ribbon;
            module.sort_mode = ParticleSortMode::YoungestFirst;
            module.render_sort_priority = 12;
            module.render_alignment = ParticleRenderAlignment::Velocity;
            module.velocity_stretch_scale = 0.25;
            module.velocity_stretch_max = 6.0;
            module.max_render_distance = 80.0;
            module.render_distance_fade_range = 12.0;
            module.render_lod_start_distance = 20.0;
            module.render_lod_end_distance = 70.0;
            module.render_lod_min_particle_scale = 0.35;
            module.render_bounds_mode = ParticleRenderBoundsMode::Automatic;
            module.render_bounds_radius = 24.0;
        }),
        trails: ParticleTrailsModule::configured(|module| {
            module.ribbon_width_scale = 1.75;
            module.ribbon_tail_width_scale = 0.25;
            module.ribbon_tail_alpha_scale = 0.15;
            module.ribbon_max_segment_length = 3.5;
            module.ribbon_join_overlap_scale = 0.4;
            module.ribbon_smoothing_segments = 4;
            module.ribbon_texture_tiling = 2.25;
            module.ribbon_texture_offset = 0.5;
            module.trail_length = 0.75;
            module.trail_segments = 5;
            module.trail_end_size_scale = 0.25;
            module.trail_end_alpha_scale = 0.1;
        }),
        texture_sheet: ParticleTextureSheetModule::configured(|module| {
            module.texture_asset_id = Some("Assets/Textures/smoke.png".to_string());
            module.texture_path = Some("/tmp/particle-smoke.png".to_string());
            module.columns = 4;
            module.rows = 2;
            module.frame_count = 7;
            module.frame_rate = 12.0;
            module.playback_mode = ParticleTextureSheetPlaybackMode::Loop;
            module.start_frame = 3;
            module.frame_randomness = 2;
        }),
    };
    original.set_component(ParticleEmitter::new(settings), entity);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let json: serde_json::Value = serde_json::from_str(&data).expect("json");
    let emitter = &json["entities"][0]["components"]["particleEmitter"];
    assert_eq!(
        emitter["settings"]["emission"]["maxSpawnedParticlesPerFrame"],
        48
    );
    assert!(emitter.get("maxSpawnedParticlesPerFrame").is_none());
    let module_stack = &emitter["moduleStack"];
    assert_eq!(
        module_stack["version"],
        ParticleModuleStack::CURRENT_VERSION
    );
    let modules = module_stack["modules"].as_array().expect("modules");
    assert_eq!(
        modules
            .iter()
            .map(|module| module["id"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>(),
        ParticleModuleStack::DEFAULT_MODULE_IDS
    );
    let emission_module = modules
        .iter()
        .find(|module| module["id"] == "emission")
        .expect("emission module");
    assert_eq!(emission_module["settings"]["type"], "emission");
    assert_eq!(
        emission_module["settings"]["payload"]["maxSpawnedParticlesPerFrame"],
        48
    );
    let texture_sheet_module = modules
        .iter()
        .find(|module| module["id"] == "textureSheet")
        .expect("texture sheet module");
    assert_eq!(texture_sheet_module["settings"]["type"], "textureSheet");
    let payload = &texture_sheet_module["settings"]["payload"];
    assert_eq!(payload["textureAssetID"], "Assets/Textures/smoke.png");
    assert_eq!(payload["playbackMode"], "loop");
    assert_eq!(payload["startFrame"], 3);
    assert_eq!(payload["frameRandomness"], 2);

    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");

    let emitter = restored
        .component::<ParticleEmitter>(restored.entities()[0])
        .expect("emitter");
    assert_eq!(emitter.settings.emission.emission_rate, 33.0);
    assert_eq!(
        emitter.settings.emission.emission_rate_curve,
        ParticleCurve::Constant(1.5)
    );
    assert_eq!(emitter.settings.emission.distance_emission_rate, 12.0);
    assert_eq!(
        emitter.settings.emission.distance_emission_rate_curve,
        ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(1.0, 2.0),
        ])
    );
    assert!(!emitter.settings.emission.looping);
    assert_eq!(emitter.settings.emission.duration, 4.5);
    assert_eq!(emitter.settings.emission.prewarm_time, 1.25);
    assert_eq!(emitter.settings.emission.prewarm_step, 0.05);
    assert_eq!(emitter.settings.emission.burst_count, 7);
    assert_eq!(emitter.settings.emission.burst_interval, 0.25);
    assert_eq!(emitter.settings.emission.max_particles, 128);
    assert_eq!(
        emitter.settings.emission.max_spawned_particles_per_frame,
        48
    );
    assert_eq!(emitter.settings.emission.max_rendered_particles, 64);
    assert_eq!(emitter.settings.appearance.lifetime, 1.5);
    assert_eq!(
        emitter.settings.sub_emitters.legacy_trigger,
        ParticleSubEmitterTrigger::Collision
    );
    assert_eq!(emitter.settings.sub_emitters.legacy_burst_count, 3);
    assert_eq!(emitter.settings.sub_emitters.legacy_probability, 0.75);
    assert_eq!(emitter.settings.sub_emitters.rules, sub_emitters);
    assert_eq!(
        emitter.settings.shape.emission_shape,
        ParticleEmissionShape::Cone
    );
    assert_eq!(emitter.settings.shape.cone_radius, 0.75);
    assert_eq!(
        emitter.settings.velocity.start_velocity,
        Float3::new(0.0, 3.0, 0.0)
    );
    assert_eq!(
        emitter.settings.forces.force_mode,
        ParticleForceMode::Vortex
    );
    assert_eq!(
        emitter.settings.forces.vector_field_mode,
        ParticleVectorFieldMode::Curl
    );
    assert_eq!(
        emitter.settings.collision.collision_mode,
        ParticleCollisionMode::WorldPlane
    );
    assert_eq!(emitter.settings.collision.collision_restitution, 0.7);
    assert_eq!(
        emitter.settings.gpu_simulation.simulation_space,
        ParticleSimulationSpace::World
    );
    assert_eq!(emitter.settings.gpu_simulation.workgroup_size, 128);
    assert_eq!(
        emitter.settings.appearance.blend_mode,
        ParticleBlendMode::Additive
    );
    assert_eq!(
        emitter.settings.renderer.render_mode,
        ParticleRenderMode::Ribbon
    );
    assert_eq!(
        emitter.settings.renderer.sort_mode,
        ParticleSortMode::YoungestFirst
    );
    assert_eq!(
        emitter.settings.renderer.render_bounds_mode,
        ParticleRenderBoundsMode::Automatic
    );
    assert_eq!(emitter.settings.trails.ribbon_width_scale, 1.75);
    assert_eq!(emitter.settings.trails.trail_length, 0.75);
    assert_eq!(
        emitter.settings.texture_sheet.texture_asset_id.as_deref(),
        Some("Assets/Textures/smoke.png")
    );
    assert_eq!(
        emitter.settings.texture_sheet.playback_mode,
        ParticleTextureSheetPlaybackMode::Loop
    );
    assert_eq!(emitter.settings.texture_sheet.start_frame, 3);
    assert_eq!(emitter.settings.emission.simulation_speed, 1.5);
    assert_eq!(emitter.settings.emission.seed, 12_345);

    let mut a = emitter.clone();
    let mut b = original
        .component::<ParticleEmitter>(original.entities()[0])
        .expect("original emitter");
    a.emit(5, None);
    b.emit(5, None);
    a.advance(0.1, None, &Default::default());
    b.advance(0.1, None, &Default::default());
    assert_eq!(a.particles(), b.particles());
}

/// Deserialize: particle emitter module stack overrides legacy fields.
#[test]
fn particle_emitter_module_stack_overrides_legacy_fields() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_component(
        ParticleEmitter::new(ParticleEmitterSettings {
            emission: ParticleEmissionModule::configured(|module| {
                module.emission_rate = 1.0;
                module.max_particles = 4;
            }),
            texture_sheet: ParticleTextureSheetModule::configured(|module| {
                module.columns = 1;
                module.rows = 1;
                module.playback_mode = ParticleTextureSheetPlaybackMode::Automatic;
            }),
            ..ParticleEmitterSettings::default()
        }),
        entity,
    );

    let overriding = ParticleEmitter::new(ParticleEmitterSettings {
        emission: ParticleEmissionModule::configured(|module| {
            module.emission_rate = 42.0;
            module.max_particles = 256;
        }),
        gpu_simulation: ParticleGPUSimulationModule::configured(|module| {
            module.workgroup_size = 128;
        }),
        collision: ParticleCollisionModule::configured(|module| {
            module.collision_restitution = 0.8;
        }),
        texture_sheet: ParticleTextureSheetModule::configured(|module| {
            module.columns = 4;
            module.rows = 2;
            module.frame_count = 7;
            module.playback_mode = ParticleTextureSheetPlaybackMode::SingleFrame;
            module.start_frame = 3;
            module.frame_randomness = 2;
        }),
        ..ParticleEmitterSettings::default()
    });
    let module_stack_value =
        serde_json::to_value(overriding.module_stack()).expect("module stack json");

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut json: serde_json::Value = serde_json::from_str(&data).expect("json");
    json["entities"][0]["components"]["particleEmitter"]["moduleStack"] = module_stack_value;
    let edited = serde_json::to_string(&json).expect("edited json");

    let mut restored = runtime();
    SceneSerializer::deserialize(&edited, restored.world_mut()).expect("deserialize");

    let emitter = restored
        .component::<ParticleEmitter>(restored.entities()[0])
        .expect("emitter");
    assert_eq!(emitter.settings.emission.emission_rate, 42.0);
    assert_eq!(emitter.settings.emission.max_particles, 256);
    assert_eq!(emitter.settings.collision.collision_restitution, 0.8);
    assert_eq!(emitter.settings.texture_sheet.columns, 4);
    assert_eq!(emitter.settings.texture_sheet.rows, 2);
    assert_eq!(emitter.settings.texture_sheet.frame_count, 7);
    assert_eq!(
        emitter.settings.texture_sheet.playback_mode,
        ParticleTextureSheetPlaybackMode::SingleFrame
    );
    assert_eq!(emitter.settings.texture_sheet.start_frame, 3);
    assert_eq!(emitter.settings.texture_sheet.frame_randomness, 2);
    assert_eq!(emitter.settings.gpu_simulation.workgroup_size, 128);
}

/// Round-trip: disabled particle modules preserve authored settings.
#[test]
fn disabled_particle_module_authoring_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();

    let mut emitter = ParticleEmitter::new(ParticleEmitterSettings {
        texture_sheet: ParticleTextureSheetModule::configured(|module| {
            module.columns = 1;
            module.rows = 1;
            module.frame_count = 1;
            module.playback_mode = ParticleTextureSheetPlaybackMode::Automatic;
        }),
        ..ParticleEmitterSettings::default()
    });
    let mut stack = emitter.module_stack();
    let index = stack
        .modules
        .iter()
        .position(|module| module.id == "textureSheet")
        .expect("texture sheet module");
    stack.modules[index].is_enabled = false;
    stack.modules[index].is_expanded = true;
    let ParticleEmitterModuleSettings::TextureSheet(mut settings) =
        stack.modules[index].settings.clone()
    else {
        panic!("expected texture sheet module settings");
    };
    settings.texture_asset_id = Some("Assets/Textures/fire-sheet.png".to_string());
    settings.texture_path = Some("/tmp/fire-sheet.png".to_string());
    settings.columns = 8;
    settings.rows = 4;
    settings.frame_count = 24;
    settings.frame_rate = 30.0;
    settings.playback_mode = ParticleTextureSheetPlaybackMode::Loop;
    settings.start_frame = 5;
    settings.frame_randomness = 3;
    stack.modules[index].settings = ParticleEmitterModuleSettings::TextureSheet(settings);
    emitter.apply(stack);
    original.set_component(emitter, entity);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");

    let mut emitter = restored
        .component::<ParticleEmitter>(restored.entities()[0])
        .expect("emitter");
    assert_eq!(emitter.settings.texture_sheet.columns, 1);
    assert_eq!(emitter.settings.texture_sheet.rows, 1);
    assert_eq!(emitter.settings.texture_sheet.frame_count, 1);
    assert_eq!(
        emitter.settings.texture_sheet.playback_mode,
        ParticleTextureSheetPlaybackMode::Automatic
    );

    let mut stack = emitter.module_stack();
    let index = stack
        .modules
        .iter()
        .position(|module| module.id == "textureSheet")
        .expect("texture sheet module");
    let module = &stack.modules[index];
    assert!(!module.is_enabled);
    assert!(module.is_expanded);
    let ParticleEmitterModuleSettings::TextureSheet(settings) = &module.settings else {
        panic!("expected texture sheet module settings");
    };
    assert_eq!(
        settings.texture_asset_id.as_deref(),
        Some("Assets/Textures/fire-sheet.png")
    );
    assert_eq!(
        settings.texture_path.as_deref(),
        Some("/tmp/fire-sheet.png")
    );
    assert_eq!(settings.columns, 8);
    assert_eq!(settings.rows, 4);
    assert_eq!(settings.frame_count, 24);
    assert_eq!(settings.frame_rate, 30.0);
    assert_eq!(
        settings.playback_mode,
        ParticleTextureSheetPlaybackMode::Loop
    );
    assert_eq!(settings.start_frame, 5);
    assert_eq!(settings.frame_randomness, 3);

    stack.modules[index].is_enabled = true;
    emitter.apply(stack);
    assert_eq!(
        emitter.settings.texture_sheet.texture_asset_id.as_deref(),
        Some("Assets/Textures/fire-sheet.png")
    );
    assert_eq!(emitter.settings.texture_sheet.columns, 8);
    assert_eq!(emitter.settings.texture_sheet.rows, 4);
    assert_eq!(emitter.settings.texture_sheet.frame_count, 24);
}

/// Round-trip: duplicated particle modules remain diagnosable and repairable.
#[test]
fn duplicated_particle_module_stack_repair_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();

    let mut emitter = ParticleEmitter::default();
    let mut malformed = emitter.module_stack();
    let renderer = malformed
        .modules
        .iter()
        .find(|module| module.id == "renderer")
        .cloned()
        .expect("renderer module");
    malformed.modules.insert(0, renderer);
    emitter.authored_module_stack = Some(malformed);
    original.set_component(emitter, entity);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");

    let mut emitter = restored
        .component::<ParticleEmitter>(restored.entities()[0])
        .expect("emitter");
    assert!(
        emitter
            .module_validation_issues()
            .iter()
            .any(|issue| issue.module_id == "renderer" && issue.code == "duplicateModule")
    );

    let mut stack = emitter.module_stack();
    stack.repair_validation_issues();
    emitter.apply(stack);

    assert!(
        !emitter
            .module_validation_issues()
            .iter()
            .any(|issue| issue.code == "duplicateModule")
    );
    assert_eq!(
        emitter
            .module_stack()
            .modules
            .iter()
            .filter(|module| module.id == "renderer")
            .count(),
        1
    );
    assert!(module_ids(&emitter.module_stack()).contains(&"trails".to_string()));
}

/// Round-trip: particle module validation and repair survive serialization.
#[test]
fn particle_module_validation_and_repair_round_trip() {
    let mut original = runtime();
    let entity = original.create_entity();
    original.set_component(
        ParticleEmitter::new(ParticleEmitterSettings {
            emission: ParticleEmissionModule::configured(|module| {
                module.emission_rate = 1.0;
                module.max_particles = 0;
            }),
            appearance: ParticleAppearanceModule::configured(|module| {
                module.lifetime = 0.0;
            }),
            gpu_simulation: ParticleGPUSimulationModule::configured(|module| {
                module.simulation_backend = ParticleSimulationBackend::GpuRequired;
                module.workgroup_size = ParticleGPUSimulationPlan::MAXIMUM_WORKGROUP_SIZE + 1;
            }),
            renderer: ParticleRendererModule::configured(|module| {
                module.render_lod_start_distance = 20.0;
                module.render_lod_end_distance = 10.0;
            }),
            texture_sheet: ParticleTextureSheetModule::configured(|module| {
                module.columns = 2;
                module.rows = 2;
                module.frame_count = 8;
            }),
            ..ParticleEmitterSettings::default()
        }),
        entity,
    );

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");

    let mut emitter = restored
        .component::<ParticleEmitter>(restored.entities()[0])
        .expect("emitter");
    let codes: Vec<String> = emitter
        .module_validation_issues()
        .iter()
        .map(|issue| issue.code.clone())
        .collect();
    assert!(codes.contains(&"noParticleCapacity".to_string()));
    assert!(codes.contains(&"invalidLifetime".to_string()));
    assert!(codes.contains(&"frameCountExceedsCells".to_string()));
    assert!(codes.contains(&"invalidLODRange".to_string()));
    assert!(codes.contains(&"gpuWorkgroupClamped".to_string()));
    assert!(codes.contains(&"gpuRequiredButUnsupported".to_string()));

    let mut stack = emitter.module_stack();
    stack.repair_validation_issues();
    emitter.apply(stack);

    let repaired: Vec<String> = emitter
        .module_validation_issues()
        .iter()
        .map(|issue| issue.code.clone())
        .collect();
    for code in [
        "noParticleCapacity",
        "invalidLifetime",
        "frameCountExceedsCells",
        "invalidLODRange",
        "gpuWorkgroupClamped",
        "gpuRequiredButUnsupported",
    ] {
        assert!(
            !repaired.contains(&code.to_string()),
            "{code} should be repaired"
        );
    }
    assert_eq!(
        ParticleGPUSimulationPlan::new(&emitter).status,
        ParticleGPUSimulationPlanStatus::Supported
    );
}

/// Round-trip: constraint reconnects to remapped entities.
#[test]
fn constraint_round_trip() {
    let mut original = runtime();
    let body_a = original.create_entity();
    original.set_component(SceneNameComponent::new("A"), body_a);
    let body_b = original.create_entity();
    original.set_component(SceneNameComponent::new("B"), body_b);
    let mut constraint = PhysicsJoint::new(
        PhysicsJointConfiguration::Hinge(
            crate::physics::joints::physics_joint_configuration::HingeJointConfiguration::new(
                Float3::new(0.0, 0.0, 1.0),
                Float3::new(0.0, 0.0, 1.0),
                -1.2,
                1.2,
                PhysicsJointMotor::default(),
                PhysicsJointSpring::default(),
            ),
        ),
        body_a,
        body_b,
        Float3::new(1.0, 0.0, 0.0),
        Float3::new(-1.0, 0.0, 0.0),
        true,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
    );
    constraint.break_force = PhysicsJoint::DEFAULT_BREAK_LIMIT;
    original.set_component(constraint, body_a);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");

    let a2 = restored.find_entity_named("A").expect("A");
    let b2 = restored.find_entity_named("B").expect("B");
    let c = restored.component::<PhysicsJoint>(a2).expect("constraint");
    assert!(matches!(
        c.configuration,
        PhysicsJointConfiguration::Hinge(_)
    ));
    assert_eq!(c.entity_a, a2);
    assert_eq!(c.entity_b, b2);
    assert_eq!(c.pivot_a, Float3::new(1.0, 0.0, 0.0));
    if let PhysicsJointConfiguration::Hinge(hinge) = &c.configuration {
        assert_eq!(hinge.minimum_angle, -1.2);
        assert_eq!(hinge.maximum_angle, 1.2);
    }
}

/// Round-trip: typed six-DOF joint preserves independent configuration.
#[test]
fn typed_joint_round_trip() {
    let mut original = runtime();
    let body_a = original.create_entity();
    original.set_component(SceneNameComponent::new("A"), body_a);
    let body_b = original.create_entity();
    original.set_component(SceneNameComponent::new("B"), body_b);
    let configuration = SixDofJointConfiguration::new(
        Float3::new(1.0, 0.0, 0.0),
        Float3::new(0.0, 0.0, 1.0),
        Float3::new(-1.0, -2.0, -3.0),
        Float3::new(1.0, 2.0, 3.0),
        Float3::new(-0.1, -0.2, -0.3),
        Float3::new(0.1, 0.2, 0.3),
        PhysicsJointMotor::new(PhysicsJointMotorMode::Velocity, 0.0, 4.0, 50.0),
        PhysicsJointMotor::new(PhysicsJointMotorMode::Position, 0.25, 0.0, 60.0),
        PhysicsJointSpring::new(3.0, 0.7),
    );
    let joint = PhysicsJoint::new(
        PhysicsJointConfiguration::SixDof(configuration),
        body_a,
        body_b,
        Float3::ZERO,
        Float3::ZERO,
        true,
        100.0,
        200.0,
    );
    original.set_component(joint, body_a);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let restored_a = restored.find_entity_named("A").expect("A");
    let restored_joint = restored
        .component::<PhysicsJoint>(restored_a)
        .expect("joint");
    assert_eq!(
        restored_joint.configuration,
        PhysicsJointConfiguration::SixDof(configuration)
    );
    assert_eq!(restored_joint.break_force, 100.0);
    assert_eq!(restored_joint.break_torque, 200.0);
}

/// Prefab capture drops a constraint whose endpoint is outside the subtree.
#[test]
fn prefab_drops_dangling_constraint() {
    let mut scene = runtime();
    let root = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Root"), root);
    let external = scene.create_entity();
    scene.set_component(
        PhysicsJoint::new(
            PhysicsJointConfiguration::Distance(
                crate::physics::joints::physics_joint_configuration::DistanceJointConfiguration::default(),
            ),
            root,
            external,
            Float3::ZERO,
            Float3::ZERO,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        ),
        root,
    );

    let prefab = Prefab::capture(scene.world(), root)
        .expect("capture")
        .expect("prefab");
    let mut target = runtime();
    let new_root = prefab
        .instantiate(target.world_mut(), None, None)
        .expect("instantiate")
        .expect("root");
    assert!(target.component::<PhysicsJoint>(new_root).is_none());
}
