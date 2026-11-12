//! World-event half of `Engine/Tests/IntentRuntimeTests/IntentRuntimeTests.swift`.

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::{
    AnimationBlendSample1D, AnimationBlendSpace1D, AnimationGraph, AnimationGraphPlayer,
    AnimationMotion, AnimationPlayer, AnimationState, AnimationStateMachine,
};
use diffuse_scene::media::audio::AudioSource;
use diffuse_scene::physics::collider::{
    Collider, ColliderShape, ColliderShapeKind, PhysicsMaterial,
};
use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
use diffuse_scene::physics::joints::physics_joint_configuration::{
    DistanceJointConfiguration, PhysicsJointConfiguration,
};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use diffuse_scene::rendering::render_extraction::{
    CameraComponent, LightComponent, LightType, RenderMaterialComponent, RenderMeshComponent,
};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_script::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use diffuse_script::interop::component_registry_script_codec::{
    ComponentRegistryScriptCodec, encode_script_binding_for_editing,
};

use super::intent_runtime_tests::{scene, scene_context};
use crate::transactions::transaction_executor::TransactionExecutor;
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionBaseRevisions, TransactionIR, TransactionOperation,
    TransactionProvenance,
};
use crate::transactions::world_event::{WorldEvent, WorldPropertyValue};

fn apply(
    scene: diffuse_scene::scene_runtime::SceneRuntime,
    summary: &str,
    operations: Vec<TransactionOperation>,
) -> (diffuse_scene::scene_runtime::SceneRuntime, Vec<WorldEvent>) {
    let mut context = scene_context(scene);
    let mut transaction = TransactionIR::new(summary, operations, TransactionProvenance::Authored);
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().revision),
        ..TransactionBaseRevisions::default()
    };
    let result = TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .expect("apply");
    (
        context.scene_runtime.take().expect("scene"),
        result.world_events,
    )
}

fn authored<'a>(events: &'a [WorldEvent], property: &str) -> Option<&'a WorldPropertyValue> {
    events.iter().find_map(|event| match event {
        WorldEvent::EntityAuthoredChanged {
            property: name,
            value,
            ..
        } if name == property => Some(value),
        _ => None,
    })
}

fn evaluated<'a>(events: &'a [WorldEvent], property: &str) -> Option<&'a WorldPropertyValue> {
    events.iter().find_map(|event| match event {
        WorldEvent::EntityEvaluatedChanged {
            property: name,
            value,
            ..
        } if name == property => Some(value),
        _ => None,
    })
}

fn number(value: f64) -> ComponentValue {
    ComponentValue::Number(value)
}

fn fields(
    entity: EntityID,
    type_id: &str,
    entries: Vec<(&str, ComponentValue)>,
) -> TransactionOperation {
    TransactionOperation::Scene(SceneMutation::component_fields(
        entity.raw_value(),
        type_id,
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), Some(value)))
            .collect::<Vec<(String, Option<ComponentValue>)>>(),
    ))
}

/// `setLocalTransform` emits `eulerDegrees` authored and
/// `worldEulerDegrees` evaluated events.
#[test]
fn set_local_transform_emits_rotation_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    let angle = std::f32::consts::PI / 4.0;
    let (sine, cosine) = angle.sin_cos();
    let transform = LocalTransform::new(Float4x4::from_columns([
        Float4::new(cosine, 0.0, -sine, 0.0),
        Float4::new(0.0, 1.0, 0.0, 0.0),
        Float4::new(sine, 0.0, cosine, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ]));
    let (_scene, events) = apply(
        scene,
        "Rotate entity",
        vec![TransactionOperation::Scene(
            SceneMutation::SetLocalTransform {
                entity_id: entity.raw_value(),
                transform,
            },
        )],
    );
    assert!(
        authored(&events, "eulerDegrees").is_some(),
        "setLocalTransform with rotation must emit eulerDegrees"
    );
}

/// `setRigidBodyMass` and `setAnimationPlayer` emit authored world events.
#[test]
fn physics_and_animation_ops_emit_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 10.0,
            ..RigidBodyOptions::default()
        }),
        entity,
    );
    scene.set_component(AnimationPlayer::default(), entity);
    let (_scene, events) = apply(
        scene,
        "Update mass and animation",
        vec![
            fields(entity, "rigidbody", vec![("mass", number(50.0))]),
            TransactionOperation::Scene(SceneMutation::component_data(
                entity.raw_value(),
                "animationPlayer",
                AnimationPlayer::new(Some("walk".to_string()), 1.5, true, true, 0.0),
                diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
            )),
        ],
    );
    assert!(authored(&events, "rigidBodyMass").is_some());
    assert!(authored(&events, "animationClip").is_some());
}

/// `setAnimationGraphPlayer` applies the component and emits authored world
/// events.
#[test]
fn set_animation_graph_player_applies_and_emits_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    let graph = AnimationGraph::new(
        vec![AnimationBlendSpace1D::new(
            "Locomotion",
            "speed",
            vec![
                AnimationBlendSample1D::new(Some("idle".to_string()), 0.0),
                AnimationBlendSample1D::new(Some("run".to_string()), 1.0),
            ],
        )],
        AnimationStateMachine::new(
            "Move",
            vec![AnimationState::new(
                "Move",
                AnimationMotion::BlendSpace1D("Locomotion".to_string()),
                1.0,
                true,
            )],
            Vec::new(),
        ),
    );
    let player = AnimationGraphPlayer::new(
        graph,
        [("speed".to_string(), 0.5)].into_iter().collect(),
        Some("Move".to_string()),
        None,
        0.0,
        0.0,
        0.0,
        0.0,
        1.25,
        true,
    );
    let (scene, events) = apply(
        scene,
        "Set animation graph",
        vec![TransactionOperation::Scene(SceneMutation::component_data(
            entity.raw_value(),
            "animationGraphPlayer",
            player.clone(),
            diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
        ))],
    );
    assert_eq!(
        scene.component::<AnimationGraphPlayer>(entity),
        Some(player)
    );
    assert!(matches!(
        authored(&events, "animationGraphSpeed"),
        Some(WorldPropertyValue::Float(value)) if (*value - 1.25).abs() < 1.0e-6
    ));
    assert_eq!(
        authored(&events, "animationGraphIsPlaying"),
        Some(&WorldPropertyValue::Bool(true))
    );
}

/// A non-uniform scale emits `worldScale`; an identity transform does not.
#[test]
fn set_local_transform_scale_emits_world_scale() {
    let mut scaled_scene = scene();
    let scaled_entity = scaled_scene.create_entity();
    let transform = LocalTransform::new(Float4x4::from_columns([
        Float4::new(2.0, 0.0, 0.0, 0.0),
        Float4::new(0.0, 3.0, 0.0, 0.0),
        Float4::new(0.0, 0.0, 1.0, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ]));
    let (_scene, events) = apply(
        scaled_scene,
        "Scale entity",
        vec![TransactionOperation::Scene(
            SceneMutation::SetLocalTransform {
                entity_id: scaled_entity.raw_value(),
                transform,
            },
        )],
    );
    match evaluated(&events, "worldScale") {
        Some(WorldPropertyValue::Vec3(x, y, z)) => {
            assert!((x - 2.0).abs() < 0.01);
            assert!((y - 3.0).abs() < 0.01);
            assert!((z - 1.0).abs() < 0.01);
        }
        other => panic!("expected worldScale vec3, got {other:?}"),
    }
}

/// An identity transform does not emit `worldScale`.
#[test]
fn set_local_transform_uniform_scale_omits_world_scale() {
    let mut identity_scene = scene();
    let identity_entity = identity_scene.create_entity();
    let (_scene, events) = apply(
        identity_scene,
        "Identity transform",
        vec![TransactionOperation::Scene(
            SceneMutation::SetLocalTransform {
                entity_id: identity_entity.raw_value(),
                transform: LocalTransform::IDENTITY,
            },
        )],
    );
    assert!(evaluated(&events, "worldScale").is_none());
}

/// `setLightCastShadows` emits the authored event.
#[test]
fn set_light_cast_shadows_emits_world_event() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        LightComponent::new(
            LightType::Directional,
            Float3::ONE,
            1.0,
            100.0,
            0.0,
            179.0,
            false,
        ),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "Enable shadow casting",
        vec![fields(
            entity,
            "light",
            vec![("castShadows", ComponentValue::Bool(true))],
        )],
    );
    assert_eq!(
        authored(&events, "lightCastShadows"),
        Some(&WorldPropertyValue::Bool(true))
    );
}

/// `setColliderLayer` and `setColliderLayerMask` emit their authored events.
#[test]
fn set_collider_layer_emits_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "Set layer",
        vec![
            fields(entity, "collider", vec![("layerID", number(3.0))]),
            fields(entity, "collider", vec![("layerMask", number(12.0))]),
        ],
    );
    assert_eq!(
        authored(&events, "colliderLayerID"),
        Some(&WorldPropertyValue::Float(3.0))
    );
    assert_eq!(
        authored(&events, "colliderLayerMask"),
        Some(&WorldPropertyValue::Float(12.0))
    );
}

/// `setConstraintEnabled` emits the authored event.
#[test]
fn set_constraint_enabled_emits_world_event() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        PhysicsJoint::new(
            PhysicsJointConfiguration::Distance(DistanceJointConfiguration::default()),
            entity,
            entity,
            Float3::ZERO,
            Float3::ZERO,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        ),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "Disable constraint",
        vec![fields(
            entity,
            "constraint",
            vec![("isEnabled", ComponentValue::Bool(false))],
        )],
    );
    assert_eq!(
        authored(&events, "constraintEnabled"),
        Some(&WorldPropertyValue::Bool(false))
    );
}

/// `setRenderMaterialComponent` emits four PBR authored events.
#[test]
fn set_render_material_component_emits_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        RenderMaterialComponent::new(
            Float4::new(1.0, 1.0, 1.0, 1.0),
            None,
            None,
            0.0,
            1.0,
            Float3::ZERO,
            None,
            None,
            None,
        ),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "Set PBR material",
        vec![fields(
            entity,
            "renderMaterial",
            vec![
                (
                    "baseColorFactor",
                    ComponentValue::Array(vec![
                        number(0.8f32 as f64),
                        number(0.2f32 as f64),
                        number(0.1f32 as f64),
                        number(1.0),
                    ]),
                ),
                ("baseColorTextureIndex", number(2.0)),
                ("normalTextureIndex", number(5.0)),
                ("metallicFactor", number(0.9)),
                ("roughnessFactor", number(0.3)),
                (
                    "emissiveFactor",
                    ComponentValue::Array(vec![number(0.0), number(0.5f32 as f64), number(0.0)]),
                ),
            ],
        )],
    );
    assert!(matches!(
        authored(&events, "materialBaseColor"),
        Some(WorldPropertyValue::Vec4(0.8, 0.2, 0.1, 1.0))
    ));
    assert!(matches!(
        authored(&events, "materialMetallic"),
        Some(WorldPropertyValue::Float(value)) if (*value - 0.9).abs() < 1.0e-6
    ));
    assert!(matches!(
        authored(&events, "materialRoughness"),
        Some(WorldPropertyValue::Float(value)) if (*value - 0.3).abs() < 1.0e-6
    ));
    assert!(matches!(
        authored(&events, "materialEmissive"),
        Some(WorldPropertyValue::Vec3(0.0, 0.5, 0.0))
    ));
}

/// `setScriptBindings` emits a JSON-string authored world event.
#[test]
fn set_script_bindings_emits_world_event() {
    let mut registry = diffuse_scene::components::core::registry::ComponentRegistry::built_in();
    registry.register_default_script_codec();
    let mut scene = diffuse_scene::scene_runtime::SceneRuntime::new(registry);
    let entity = scene.create_entity();
    scene.set_component(ScriptComponent::new(Vec::new()), entity);
    let binding = ScriptBinding::new(
        ScriptHandle::new(42),
        ScriptBindingID::new(),
        Some("project.runner".to_string()),
        true,
        r#"{"speed":5}"#,
    );
    let value = ComponentValue::Object(
        [(
            "bindings".to_string(),
            ComponentValue::Array(vec![ComponentValue::Object(
                encode_script_binding_for_editing(&binding),
            )]),
        )]
        .into_iter()
        .collect(),
    );
    let (_scene, events) = apply(
        scene,
        "Attach script",
        vec![TransactionOperation::Scene(
            SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id: "script".to_string(),
                value,
                mode: diffuse_scene::components::editing::ComponentWriteMode::Replace,
            },
        )],
    );
    match authored(&events, "scriptBindings") {
        Some(WorldPropertyValue::String(json)) => {
            assert!(json.contains("42"));
            assert!(json.contains("project.runner"));
            assert!(json.contains("speed"));
        }
        other => panic!("expected scriptBindings string, got {other:?}"),
    }
}

/// `setAudioSource` emits all four authored events.
#[test]
fn set_audio_source_emits_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(AudioSource::default(), entity);
    let source = AudioSource::new("ambient", 0.75, 1.0, true, false, 1.0);
    let (_scene, events) = apply(
        scene,
        "Set audio",
        vec![TransactionOperation::Scene(SceneMutation::component_data(
            entity.raw_value(),
            "audioSource",
            source,
            diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
        ))],
    );
    assert_eq!(
        authored(&events, "audioClip"),
        Some(&WorldPropertyValue::String("ambient".to_string()))
    );
    assert_eq!(
        authored(&events, "audioVolume"),
        Some(&WorldPropertyValue::Float(0.75))
    );
    assert_eq!(
        authored(&events, "audioLoop"),
        Some(&WorldPropertyValue::Bool(true))
    );
    assert_eq!(
        authored(&events, "audioPlayOnAwake"),
        Some(&WorldPropertyValue::Bool(false))
    );
}

/// `setCollider` emits all seven authored events.
#[test]
fn set_collider_emits_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    let mut collider = Collider::with_shape(ColliderShape::Sphere {
        radius: 1.5,
        center: Float3::ZERO,
    });
    collider.is_trigger = true;
    collider.layer_id = 3;
    collider.layer_mask = 15;
    collider.material = PhysicsMaterial::new(0.4, 0.2, 2.0);
    let (_scene, events) = apply(
        scene,
        "Set collider",
        vec![TransactionOperation::Scene(SceneMutation::component_data(
            entity.raw_value(),
            "collider",
            collider,
            diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
        ))],
    );
    assert_eq!(
        authored(&events, "colliderShape"),
        Some(&WorldPropertyValue::String("sphere".to_string()))
    );
    assert_eq!(
        authored(&events, "colliderIsTrigger"),
        Some(&WorldPropertyValue::Bool(true))
    );
    assert_eq!(
        authored(&events, "colliderFriction"),
        Some(&WorldPropertyValue::Float(0.4))
    );
    assert_eq!(
        authored(&events, "colliderRestitution"),
        Some(&WorldPropertyValue::Float(0.2))
    );
    assert_eq!(
        authored(&events, "colliderDensity"),
        Some(&WorldPropertyValue::Float(2.0))
    );
    assert_eq!(
        authored(&events, "colliderLayerID"),
        Some(&WorldPropertyValue::Float(3.0))
    );
    assert_eq!(
        authored(&events, "colliderLayerMask"),
        Some(&WorldPropertyValue::Float(15.0))
    );
}

/// Rigid-body motion type, gravity scale and allow-sleep emit authored events.
#[test]
fn rigid_body_ops_emit_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 10.0,
            ..RigidBodyOptions::default()
        }),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "rb ops",
        vec![
            fields(
                entity,
                "rigidbody",
                vec![(
                    "motionType",
                    ComponentValue::String(RigidBodyMotionType::Kinematic.raw_value().to_string()),
                )],
            ),
            fields(entity, "rigidbody", vec![("gravityScale", number(2.5))]),
            fields(
                entity,
                "rigidbody",
                vec![("allowSleep", ComponentValue::Bool(false))],
            ),
        ],
    );
    assert_eq!(
        authored(&events, "rigidBodyMotionType"),
        Some(&WorldPropertyValue::String("kinematic".to_string()))
    );
    assert_eq!(
        authored(&events, "rigidBodyGravityScale"),
        Some(&WorldPropertyValue::Float(2.5))
    );
    assert_eq!(
        authored(&events, "rigidBodyAllowSleep"),
        Some(&WorldPropertyValue::Bool(false))
    );
}

/// Mesh color and visibility emit authored events.
#[test]
fn mesh_color_and_visibility_emit_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        RenderMeshComponent::new(0, true, Float3::ONE, None, Vec::new()),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "mesh events",
        vec![
            fields(
                entity,
                "renderMesh",
                vec![(
                    "colorTint",
                    ComponentValue::Array(vec![number(1.0), number(0.5f32 as f64), number(0.0)]),
                )],
            ),
            fields(
                entity,
                "renderMesh",
                vec![("isVisible", ComponentValue::Bool(false))],
            ),
        ],
    );
    assert!(matches!(
        authored(&events, "meshColor"),
        Some(WorldPropertyValue::Vec3(1.0, 0.5, 0.0))
    ));
    assert_eq!(
        authored(&events, "meshIsVisible"),
        Some(&WorldPropertyValue::Bool(false))
    );
}

/// Light type, color, intensity and range emit authored events.
#[test]
fn light_property_ops_emit_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        LightComponent::new(LightType::Point, Float3::ONE, 1.0, 10.0, 0.0, 179.0, false),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "light ops",
        vec![
            fields(
                entity,
                "light",
                vec![(
                    "type",
                    ComponentValue::String(LightType::Spot.raw_value().to_string()),
                )],
            ),
            fields(
                entity,
                "light",
                vec![(
                    "color",
                    ComponentValue::Array(vec![
                        number(0.9f32 as f64),
                        number(0.8f32 as f64),
                        number(0.7f32 as f64),
                    ]),
                )],
            ),
            fields(entity, "light", vec![("intensity", number(500.0))]),
            fields(entity, "light", vec![("range", number(25.0))]),
        ],
    );
    assert_eq!(
        authored(&events, "lightType"),
        Some(&WorldPropertyValue::String("spot".to_string()))
    );
    assert!(matches!(
        authored(&events, "lightColor"),
        Some(WorldPropertyValue::Vec3(0.9, 0.8, 0.7))
    ));
    assert_eq!(
        authored(&events, "lightIntensity"),
        Some(&WorldPropertyValue::Float(500.0))
    );
    assert_eq!(
        authored(&events, "lightRange"),
        Some(&WorldPropertyValue::Float(25.0))
    );
}

/// Spot inner/outer angles emit authored events.
#[test]
fn light_spot_angles_emit_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        LightComponent::new(LightType::Spot, Float3::ONE, 100.0, 20.0, 15.0, 40.0, false),
        entity,
    );
    let (_scene, events) = apply(
        scene,
        "spot angles",
        vec![
            fields(
                entity,
                "light",
                vec![("spotInnerAngleDegrees", number(20.0))],
            ),
            fields(
                entity,
                "light",
                vec![("spotOuterAngleDegrees", number(45.0))],
            ),
        ],
    );
    assert_eq!(
        authored(&events, "lightSpotInner"),
        Some(&WorldPropertyValue::Float(20.0))
    );
    assert_eq!(
        authored(&events, "lightSpotOuter"),
        Some(&WorldPropertyValue::Float(45.0))
    );
}

/// Camera mutations emit authored events.
#[test]
fn camera_ops_emit_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(CameraComponent::default(), entity);
    let (scene, events) = apply(
        scene,
        "camera ops",
        vec![
            fields(
                entity,
                "camera",
                vec![(
                    "fovYRadians",
                    number((75.0f32 * std::f32::consts::PI / 180.0) as f64),
                )],
            ),
            fields(
                entity,
                "camera",
                vec![("aspectRatio", number(1.777f32 as f64))],
            ),
            fields(
                entity,
                "camera",
                vec![("isActive", ComponentValue::Bool(true))],
            ),
        ],
    );
    assert!(matches!(
        authored(&events, "cameraFovYDegrees"),
        Some(WorldPropertyValue::Float(value)) if (*value - 75.0).abs() < 0.01
    ));
    assert!(matches!(
        authored(&events, "cameraAspectRatio"),
        Some(WorldPropertyValue::Float(value)) if (*value - 1.777).abs() < 0.001
    ));
    assert_eq!(
        authored(&events, "cameraIsActive"),
        Some(&WorldPropertyValue::Bool(true))
    );
    assert_eq!(
        scene
            .component::<CameraComponent>(entity)
            .map(|camera| camera.aspect_ratio),
        Some(1.777)
    );
}

/// Granular collider mutations emit individual authored events.
#[test]
fn granular_collider_ops_emit_world_events() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let sphere_fields =
        ComponentValue::Object(ColliderShapeKind::Sphere.default_component_fields());
    let (_scene, events) = apply(
        scene,
        "collider ops",
        vec![
            fields(
                entity,
                "collider",
                vec![(
                    "shapes",
                    ComponentValue::Object(
                        [("0".to_string(), sphere_fields)].into_iter().collect(),
                    ),
                )],
            ),
            fields(
                entity,
                "collider",
                vec![("isTrigger", ComponentValue::Bool(true))],
            ),
            fields(entity, "collider", vec![("friction", number(0.3))]),
            fields(entity, "collider", vec![("restitution", number(0.6))]),
            fields(entity, "collider", vec![("density", number(1.5))]),
        ],
    );
    assert_eq!(
        authored(&events, "colliderShape"),
        Some(&WorldPropertyValue::String("sphere".to_string()))
    );
    assert_eq!(
        authored(&events, "colliderIsTrigger"),
        Some(&WorldPropertyValue::Bool(true))
    );
    assert_eq!(
        authored(&events, "colliderFriction"),
        Some(&WorldPropertyValue::Float(0.3))
    );
    assert_eq!(
        authored(&events, "colliderRestitution"),
        Some(&WorldPropertyValue::Float(0.6))
    );
    assert_eq!(
        authored(&events, "colliderDensity"),
        Some(&WorldPropertyValue::Float(1.5))
    );
}

/// `setColliderShapeType` updates the collider while preserving other fields.
#[test]
fn set_collider_shape_type_updates_component() {
    let mut scene = scene();
    let entity = scene.create_entity();
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::ONE,
        center: Float3::ZERO,
    });
    collider.is_trigger = true;
    collider.layer_id = 2;
    collider.layer_mask = 7;
    collider.material = PhysicsMaterial::new(0.3, 0.7, 2.0);
    scene.set_component(collider, entity);
    let sphere_fields =
        ComponentValue::Object(ColliderShapeKind::Sphere.default_component_fields());
    let (scene, _events) = apply(
        scene,
        "to sphere",
        vec![fields(
            entity,
            "collider",
            vec![(
                "shapes",
                ComponentValue::Object([("0".to_string(), sphere_fields)].into_iter().collect()),
            )],
        )],
    );
    let collider = scene.component::<Collider>(entity).expect("collider");
    assert!(matches!(collider.shape(), ColliderShape::Sphere { .. }));
    assert!(collider.is_trigger);
    assert_eq!(collider.layer_id, 2);
    assert!((collider.material.friction - 0.3).abs() < 0.001);
}

/// `setSceneName` emits the `name` authored event.
#[test]
fn set_scene_name_emits_world_event() {
    let mut scene = scene();
    let entity = scene.create_entity();
    let (_scene, events) = apply(
        scene,
        "rename",
        vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
            entity_id: entity.raw_value(),
            value: "Hero".to_string(),
        })],
    );
    assert_eq!(
        authored(&events, "name"),
        Some(&WorldPropertyValue::String("Hero".to_string()))
    );
}
