//! Ported from `Editor/Tests/EditorCoreTests/EditorInspectorSectionsTests.swift`
//! (camera, audio listener and animation graph cases).

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::media::animation::{
    AnimationBlendSample1D, AnimationBlendSpace1D, AnimationGraph, AnimationGraphPlayer,
    AnimationMotion, AnimationState, AnimationStateMachine,
};
use diffuse_scene::media::audio::AudioListener;
use diffuse_scene::rendering::render_extraction::CameraComponent;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{EditorInspectorFieldValue, EditorInspectorSection};
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    )
}

fn make_entity(adapter: &EditorSceneAdapter) -> u64 {
    adapter
        .with_scene_mut(|scene| scene.create_entity())
        .raw_value()
}

fn field(
    adapter: &EditorSceneAdapter,
    raw_id: u64,
    section: &str,
    field: &str,
) -> Option<EditorInspectorFieldValue> {
    adapter
        .inspector_sections(Some(raw_id))
        .into_iter()
        .find(|candidate| candidate.id == section)
        .and_then(|section: EditorInspectorSection| {
            section
                .fields
                .into_iter()
                .find(|candidate| candidate.id == field)
        })
        .map(|field| field.value)
}

fn has_section(adapter: &EditorSceneAdapter, raw_id: u64, id: &str) -> bool {
    adapter
        .inspector_sections(Some(raw_id))
        .iter()
        .any(|section| section.id == id)
}

/// Camera section appears only when the entity has a camera.
#[test]
fn camera_section_presence() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(!has_section(&adapter, id, "camera"));
    assert!(adapter.add_component("camera", id));
    assert!(has_section(&adapter, id, "camera"));
}

/// Camera active binding writes back to the component.
#[test]
fn camera_active_binding() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("camera", id));
    let Some(EditorInspectorFieldValue::Bool(binding)) =
        field(&adapter, id, "camera", "camera-active")
    else {
        panic!("expected camera-active bool field");
    };
    binding.set(true);
    assert_eq!(
        adapter
            .scene()
            .component::<CameraComponent>(diffuse_scene::entity_id::EntityID::from_raw_value(id))
            .map(|camera| camera.is_active),
        Some(true)
    );
}

/// Camera FOV binding shows degrees and stores radians.
#[test]
fn camera_fov_binding() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("camera", id));
    let Some(EditorInspectorFieldValue::ConstrainedNumber { binding, .. }) =
        field(&adapter, id, "camera", "camera-fov")
    else {
        panic!("expected camera-fov number field");
    };
    binding.set(90.0);
    let radians = adapter
        .scene()
        .component::<CameraComponent>(diffuse_scene::entity_id::EntityID::from_raw_value(id))
        .map(|camera| camera.fov_y_radians)
        .expect("camera");
    assert!((radians - std::f32::consts::FRAC_PI_2).abs() < 1e-4);
    assert!((binding.get() - 90.0).abs() < 1e-3);
}

/// Camera aspect binding writes back to the component.
#[test]
fn camera_aspect_binding() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("camera", id));
    let Some(EditorInspectorFieldValue::ConstrainedNumber { binding, .. }) =
        field(&adapter, id, "camera", "camera-aspect")
    else {
        panic!("expected camera-aspect number field");
    };
    binding.set(1.777);
    let aspect = adapter
        .scene()
        .component::<CameraComponent>(diffuse_scene::entity_id::EntityID::from_raw_value(id))
        .map(|camera| camera.aspect_ratio)
        .expect("camera");
    assert!((aspect - 1.777).abs() < 1e-4);
    assert!((binding.get() - 1.777).abs() < 1e-4);
}

/// Audio listener volume binding writes back.
#[test]
fn audio_listener_binding() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("audioListener", id));
    assert!(has_section(&adapter, id, "audio-listener"));
    let Some(EditorInspectorFieldValue::ConstrainedNumber { binding, .. }) =
        field(&adapter, id, "audio-listener", "audio-listener-volume")
    else {
        panic!("expected master volume field");
    };
    binding.set(0.25);
    assert_eq!(
        adapter
            .scene()
            .component::<AudioListener>(diffuse_scene::entity_id::EntityID::from_raw_value(id))
            .map(|listener| listener.master_volume),
        Some(0.25)
    );
}

/// Animation graph definition JSON binding writes back.
#[test]
fn animation_graph_definition_binding() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    assert!(adapter.add_component("animationGraphPlayer", id));
    let Some(EditorInspectorFieldValue::Json { binding, .. }) = field(
        &adapter,
        id,
        "animation-graph-player",
        "anim-graph-definition",
    ) else {
        panic!("expected animation graph definition JSON field");
    };
    let graph = AnimationGraph::new(
        vec![AnimationBlendSpace1D::new(
            "Locomotion",
            "speed",
            vec![
                AnimationBlendSample1D::new(Some("idle".to_string()), 0.0),
                AnimationBlendSample1D::new(Some("walk".to_string()), 1.0),
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
    binding.set(serde_json::to_string_pretty(&graph).expect("encode graph"));
    let player = adapter
        .scene()
        .component::<AnimationGraphPlayer>(entity)
        .expect("graph player");
    assert_eq!(player.graph, graph);
    assert_eq!(player.active_state.as_deref(), Some("Move"));
    assert!(binding.get().contains("\"blendSpace1D\""));
}

/// Physics settings inspector authors the preferred world configuration.
#[test]
fn physics_settings_bindings() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
    use diffuse_scene::physics::physics_types::PhysicsSimulationMode;

    use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(has_section(&adapter, id, "physics-settings"));

    let Some(EditorInspectorFieldValue::StringOptions { binding: mode, .. }) =
        field(&adapter, id, "physics-settings", "physics-simulation-mode")
    else {
        panic!("expected mode options");
    };
    let Some(EditorInspectorFieldValue::Vector3 {
        x: gravity_x,
        y: gravity_y,
        z: gravity_z,
    }) = field(&adapter, id, "physics-settings", "physics-gravity")
    else {
        panic!("expected gravity vector");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: fixed_step,
        ..
    }) = field(&adapter, id, "physics-settings", "physics-fixed-step")
    else {
        panic!("expected fixed step");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: max_substeps,
        ..
    }) = field(&adapter, id, "physics-settings", "physics-max-substeps")
    else {
        panic!("expected max substeps");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: collision_steps,
        ..
    }) = field(&adapter, id, "physics-settings", "physics-collision-steps")
    else {
        panic!("expected collision steps");
    };
    let Some(EditorInspectorFieldValue::Bool(allow_sleep)) =
        field(&adapter, id, "physics-settings", "physics-allow-sleep")
    else {
        panic!("expected allow sleep");
    };

    mode.set(PhysicsSimulationMode::Preview.inspector_option_id());
    gravity_x.set(1.0);
    gravity_y.set(-20.0);
    gravity_z.set(2.0);
    fixed_step.set(1.0 / 120.0);
    max_substeps.set(8.0);
    collision_steps.set(3.0);
    allow_sleep.set(false);

    let settings = adapter.scene().physics_settings();
    assert_eq!(settings.backend_kind, PhysicsBackendKind::preferred());
    assert_eq!(settings.simulation_mode, PhysicsSimulationMode::Preview);
    assert_eq!(settings.gravity, Float3::new(1.0, -20.0, 2.0));
    assert!((settings.fixed_time_step_seconds - 1.0 / 120.0).abs() < 0.000_001);
    assert_eq!(settings.max_substeps_per_frame, 8);
    assert_eq!(settings.collision_steps, 3);
    assert!(!settings.allow_sleep);
}

/// Physics settings inspector offers Natsel and disabled physics.
#[test]
fn physics_backend_selection() {
    use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;

    use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert_eq!(
        PhysicsBackendKind::ALL,
        [PhysicsBackendKind::None, PhysicsBackendKind::Natsel]
    );
    assert!(field(&adapter, id, "physics-settings", "physics-max-body-pairs").is_none());

    let Some(EditorInspectorFieldValue::StringOptions {
        binding: backend, ..
    }) = field(&adapter, id, "physics-settings", "physics-backend")
    else {
        panic!("expected physics backend options");
    };
    backend.set(PhysicsBackendKind::Natsel.inspector_option_id());
    assert_eq!(
        adapter.scene().physics_settings().backend_kind,
        PhysicsBackendKind::Natsel
    );
    assert!(field(&adapter, id, "physics-settings", "physics-max-body-pairs").is_none());
    backend.set(PhysicsBackendKind::None.inspector_option_id());
    assert_eq!(
        adapter.scene().physics_settings().backend_kind,
        PhysicsBackendKind::None
    );
    assert!(field(&adapter, id, "physics-settings", "physics-max-body-pairs").is_none());
}

/// Rigid body inspector edits rigid-body velocity damping and CCD settings.
#[test]
fn rigid_body_physics_settings_bindings() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::physics::rigid_body::RigidBody;

    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    assert!(adapter.add_component("rigidbody", id));

    let Some(EditorInspectorFieldValue::Vector3 {
        x: linear_x,
        y: linear_y,
        z: linear_z,
    }) = field(&adapter, id, "rigid-body", "linear-velocity")
    else {
        panic!("expected linear velocity field");
    };
    linear_x.set(1.0);
    linear_y.set(2.0);
    linear_z.set(3.0);

    let Some(EditorInspectorFieldValue::Vector3 {
        x: angular_x,
        y: angular_y,
        z: angular_z,
    }) = field(&adapter, id, "rigid-body", "angular-velocity")
    else {
        panic!("expected angular velocity field");
    };
    angular_x.set(4.0);
    angular_y.set(5.0);
    angular_z.set(6.0);

    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: linear_damping,
        ..
    }) = field(&adapter, id, "rigid-body", "linear-damping")
    else {
        panic!("expected linear damping");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: angular_damping,
        ..
    }) = field(&adapter, id, "rigid-body", "angular-damping")
    else {
        panic!("expected angular damping");
    };
    let Some(EditorInspectorFieldValue::Bool(ccd)) =
        field(&adapter, id, "rigid-body", "continuous-collision-detection")
    else {
        panic!("expected ccd");
    };
    linear_damping.set(0.25);
    angular_damping.set(0.5);
    ccd.set(true);

    let body = adapter
        .scene()
        .component::<RigidBody>(entity)
        .expect("rigid body");
    assert_eq!(body.linear_velocity, Float3::new(1.0, 2.0, 3.0));
    assert_eq!(body.angular_velocity, Float3::new(4.0, 5.0, 6.0));
    assert_eq!(body.linear_damping, 0.25);
    assert_eq!(body.angular_damping, 0.5);
    assert!(body.continuous_collision_detection);
}

/// Vehicle inspector exposes authored controls and writes them back.
#[test]
fn vehicle_bindings() {
    use diffuse_scene::physics::vehicles::vehicle::Vehicle;
    use diffuse_scene::physics::vehicles::vehicle_controller_configuration::{
        VehicleControllerConfiguration, VehicleControllerKind,
    };

    use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    assert!(!has_section(&adapter, id, "vehicle"));
    assert!(adapter.add_component("vehicle", id));
    assert!(has_section(&adapter, id, "vehicle"));

    let Some(EditorInspectorFieldValue::Bool(enabled)) =
        field(&adapter, id, "vehicle", "vehicle-enabled")
    else {
        panic!("expected enabled");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: max_torque,
        ..
    }) = field(&adapter, id, "vehicle", "vehicle-max-torque")
    else {
        panic!("expected max torque");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: clutch_strength,
        ..
    }) = field(&adapter, id, "vehicle", "vehicle-clutch-strength")
    else {
        panic!("expected clutch strength");
    };
    let Some(EditorInspectorFieldValue::StringOptions {
        binding: controller_kind,
        ..
    }) = field(&adapter, id, "vehicle", "vehicle-controller")
    else {
        panic!("expected controller");
    };
    enabled.set(false);
    max_torque.set(780.0);
    clutch_strength.set(18.0);

    let vehicle = adapter
        .scene()
        .component::<Vehicle>(entity)
        .expect("vehicle");
    assert!(!vehicle.is_enabled);
    assert_eq!(vehicle.engine.max_torque, 780.0);
    assert_eq!(vehicle.transmission.clutch_strength, 18.0);

    controller_kind.set(VehicleControllerKind::Tracked.inspector_option_id());
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: track_forward_friction,
        ..
    }) = field(
        &adapter,
        id,
        "vehicle",
        "vehicle-track-longitudinal-friction",
    )
    else {
        panic!("expected tracked forward friction");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: track_side_friction,
        ..
    }) = field(&adapter, id, "vehicle", "vehicle-track-lateral-friction")
    else {
        panic!("expected tracked side friction");
    };
    track_forward_friction.set(5.0);
    track_side_friction.set(2.5);
    let Some(VehicleControllerConfiguration::Tracked(tracked)) = adapter
        .scene()
        .component::<Vehicle>(entity)
        .map(|vehicle| vehicle.controller)
    else {
        panic!("expected tracked vehicle component");
    };
    assert_eq!(tracked.longitudinal_friction, 5.0);
    assert_eq!(tracked.lateral_friction, 2.5);

    let Some(EditorInspectorFieldValue::StringOptions {
        binding: updated_controller_kind,
        ..
    }) = field(&adapter, id, "vehicle", "vehicle-controller")
    else {
        panic!("expected updated controller selector");
    };
    updated_controller_kind.set(VehicleControllerKind::Motorcycle.inspector_option_id());
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: max_lean, ..
    }) = field(&adapter, id, "vehicle", "vehicle-motorcycle-max-lean")
    else {
        panic!("expected max lean");
    };
    let Some(EditorInspectorFieldValue::Bool(lean_enabled)) =
        field(&adapter, id, "vehicle", "vehicle-motorcycle-lean-enabled")
    else {
        panic!("expected lean enabled");
    };
    max_lean.set(0.6);
    lean_enabled.set(false);
    let Some(VehicleControllerConfiguration::Motorcycle(motorcycle)) = adapter
        .scene()
        .component::<Vehicle>(entity)
        .map(|vehicle| vehicle.controller)
    else {
        panic!("expected motorcycle vehicle component");
    };
    assert_eq!(motorcycle.max_lean_angle, 0.6);
    assert!(!motorcycle.is_lean_controller_enabled);

    assert!(adapter.remove_component("vehicle", id));
    assert!(!has_section(&adapter, id, "vehicle"));
}

/// Destructible inspector edits pre-fracture thresholds and recycling policy.
#[test]
fn destructible_bindings() {
    use diffuse_scene::physics::destruction::Destructible;

    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    assert!(adapter.add_component("destructible", id));
    assert!(has_section(&adapter, id, "destructible"));

    let Some(EditorInspectorFieldValue::Bool(enabled)) =
        field(&adapter, id, "destructible", "destructible-enabled")
    else {
        panic!("expected enabled");
    };
    let Some(EditorInspectorFieldValue::Text(asset)) =
        field(&adapter, id, "destructible", "destructible-asset")
    else {
        panic!("expected asset");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: damage, ..
    }) = field(
        &adapter,
        id,
        "destructible",
        "destructible-damage-threshold",
    )
    else {
        panic!("expected damage");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: impulse, ..
    }) = field(
        &adapter,
        id,
        "destructible",
        "destructible-impulse-threshold",
    )
    else {
        panic!("expected impulse");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: budget, ..
    }) = field(&adapter, id, "destructible", "destructible-fragment-budget")
    else {
        panic!("expected budget");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: lifetime, ..
    }) = field(&adapter, id, "destructible", "destructible-lifetime")
    else {
        panic!("expected lifetime");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: recycle_delay,
        ..
    }) = field(&adapter, id, "destructible", "destructible-sleep-recycle")
    else {
        panic!("expected recycle delay");
    };
    enabled.set(false);
    asset.set("tower.prefractured".to_string());
    damage.set(80.0);
    impulse.set(14.0);
    budget.set(96.0);
    lifetime.set(25.0);
    recycle_delay.set(4.0);

    let destructible = adapter
        .scene()
        .component::<Destructible>(entity)
        .expect("destructible");
    assert!(!destructible.is_enabled);
    assert_eq!(destructible.asset_resource_id, "tower.prefractured");
    assert_eq!(destructible.damage_threshold, 80.0);
    assert_eq!(destructible.impulse_threshold, 14.0);
    assert_eq!(destructible.fragment_budget, 96);
    assert_eq!(destructible.maximum_fragment_lifetime_seconds, 25.0);
    assert_eq!(destructible.sleeping_recycle_delay_seconds, 4.0);
    let Some(EditorInspectorFieldValue::ReadOnly(fracture_state)) =
        field(&adapter, id, "destructible", "destructible-fracture-state")
    else {
        panic!("expected fracture state");
    };
    let Some(EditorInspectorFieldValue::ReadOnly(retained_fragments)) = field(
        &adapter,
        id,
        "destructible",
        "destructible-retained-fragments",
    ) else {
        panic!("expected retained fragments");
    };
    assert_eq!(fracture_state, "Intact");
    assert_eq!(retained_fragments, "0");

    assert!(adapter.remove_component("destructible", id));
    assert!(!has_section(&adapter, id, "destructible"));
}

/// Collider inspector edits collider shape center and collision mask.
#[test]
fn collider_physics_settings_bindings() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::physics::collider::Collider;

    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    assert!(adapter.add_component("collider", id));

    let Some(EditorInspectorFieldValue::Vector3 {
        x: center_x,
        y: center_y,
        z: center_z,
    }) = field(&adapter, id, "collider", "shape-center")
    else {
        panic!("expected shape center");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: layer_mask,
        ..
    }) = field(&adapter, id, "collider", "layer-mask")
    else {
        panic!("expected layer mask");
    };
    center_x.set(1.0);
    center_y.set(2.0);
    center_z.set(3.0);
    layer_mask.set(f32::from(0x00F0u16));

    let collider = adapter
        .scene()
        .component::<Collider>(entity)
        .expect("collider");
    assert_eq!(collider.shape().center(), Float3::new(1.0, 2.0, 3.0));
    assert_eq!(collider.layer_mask, 0x00F0);
}

/// Compound collider inspector round-trips child transforms and keeps shape
/// fields aligned.
#[test]
fn compound_collider_bindings_and_shape_field_alignment() {
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    use diffuse_scene::physics::collider::{
        Collider, ColliderShape, ColliderShapeInstance, ColliderShapeKind,
    };

    use crate::scene::inspector::enum_options::EditorInspectorEnumOption;
    use crate::scene::manifest::physics::collider_inspector::EditorSceneManifestColliderShapeInstance;

    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    let authored_shapes = vec![
        ColliderShapeInstance::with_transform(
            ColliderShape::Capsule {
                radius: 0.4,
                half_height: 1.2,
                center: Float3::new(0.0, 0.1, 0.0),
            },
            Float3::new(1.0, 2.0, 3.0),
            Float4::new(0.0, 0.707_106_77, 0.0, 0.707_106_77),
            Float3::new(1.0, 2.0, 1.0),
        ),
        ColliderShapeInstance::with_transform(
            ColliderShape::Sphere {
                radius: 0.75,
                center: Float3::ZERO,
            },
            Float3::new(-2.0, 0.0, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
            Float3::ONE,
        ),
    ];
    adapter.with_scene_mut(|scene| {
        scene.set_component(Collider::with_shapes(authored_shapes.clone()), entity);
    });

    assert!(field(&adapter, id, "collider", "shape-capsule-half-height").is_some());
    let Some(EditorInspectorFieldValue::ReadOnly(shape_count)) =
        field(&adapter, id, "collider", "shape-instance-count")
    else {
        panic!("expected shape count");
    };
    let Some(EditorInspectorFieldValue::ColliderShapeInstances(shape_instances)) =
        field(&adapter, id, "collider", "shape-instances")
    else {
        panic!("expected shape instances");
    };
    let Some(EditorInspectorFieldValue::Json {
        binding: shapes_json,
        ..
    }) = field(&adapter, id, "collider", "shape-instances-json")
    else {
        panic!("expected shape JSON");
    };
    assert_eq!(shape_count, "2");
    assert!(shapes_json.get().contains("localPosition"));
    assert!(shapes_json.get().contains("capsule"));
    let reversed_shapes: Vec<ColliderShapeInstance> =
        authored_shapes.iter().rev().cloned().collect();
    shape_instances.set(reversed_shapes.clone());
    assert_eq!(
        adapter
            .scene()
            .component::<Collider>(entity)
            .map(|collider| collider.shapes),
        Some(reversed_shapes)
    );
    shape_instances.set(authored_shapes.clone());

    let replacement_shapes = vec![
        ColliderShapeInstance::with_transform(
            ColliderShape::Cylinder {
                radius: 0.6,
                half_height: 1.4,
                center: Float3::new(0.0, 0.25, 0.0),
            },
            Float3::new(4.0, 5.0, 6.0),
            Float4::new(0.1, 0.2, 0.3, 0.9),
            Float3::new(0.5, 1.5, 2.0),
        ),
        ColliderShapeInstance::with_transform(
            ColliderShape::Box {
                half_extents: Float3::new(1.0, 2.0, 3.0),
                center: Float3::ZERO,
            },
            Float3::new(-1.0, -2.0, -3.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
            Float3::ONE,
        ),
    ];
    let encoded: Vec<EditorSceneManifestColliderShapeInstance> = replacement_shapes
        .iter()
        .map(EditorSceneManifestColliderShapeInstance::new)
        .collect();
    shapes_json.set(serde_json::to_string_pretty(&encoded).expect("encode shapes"));

    let updated = adapter
        .scene()
        .component::<Collider>(entity)
        .expect("collider");
    assert_eq!(updated.shapes, replacement_shapes);
    assert!(field(&adapter, id, "collider", "shape-cylinder-radius").is_some());
    assert!(field(&adapter, id, "collider", "shape-cylinder-half-height").is_some());
    assert!(field(&adapter, id, "collider", "shape-capsule-half-height").is_none());

    let Some(EditorInspectorFieldValue::StringOptions { binding: kind, .. }) =
        field(&adapter, id, "collider", "shape-kind")
    else {
        panic!("expected shape kind field");
    };
    kind.set(ColliderShapeKind::HeightField.inspector_option_id());
    assert!(field(&adapter, id, "collider", "shape-heightfield-resource").is_some());
    assert!(field(&adapter, id, "collider", "shape-capsule-half-height").is_none());
    assert!(field(&adapter, id, "collider", "shape-cylinder-half-height").is_none());
}

/// Typed physics joint inspector edits hinge and SixDOF configurations.
#[test]
fn typed_physics_joint_bindings() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::physics::collider::{Collider, ColliderShape};
    use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
    use diffuse_scene::physics::joints::physics_joint_configuration::{
        HingeJointConfiguration, PhysicsJointConfiguration, PhysicsJointKind, PhysicsJointMotor,
        PhysicsJointMotorMode,
    };

    use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

    let adapter = adapter();
    let (body_a, body_b, body_c, joint_entity) = adapter.with_scene_mut(|scene| {
        let body_a = scene.create_entity();
        let body_b = scene.create_entity();
        let body_c = scene.create_entity();
        let joint_entity = scene.create_entity();
        for body in [body_a, body_b, body_c] {
            scene.set_component(
                Collider::with_shape(ColliderShape::Box {
                    half_extents: Float3::splat(0.5),
                    center: Float3::ZERO,
                }),
                body,
            );
        }
        (body_a, body_b, body_c, joint_entity)
    });
    let joint = PhysicsJoint::new(
        PhysicsJointConfiguration::Hinge(HingeJointConfiguration::new(
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            -0.5,
            0.75,
            PhysicsJointMotor::new(PhysicsJointMotorMode::Velocity, 0.0, 2.0, 50.0),
            diffuse_scene::physics::joints::physics_joint_configuration::PhysicsJointSpring::new(
                3.0, 0.4,
            ),
        )),
        body_a,
        body_b,
        Float3::ZERO,
        Float3::ZERO,
        true,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
    );
    adapter.with_scene_mut(|scene| {
        scene.set_component(joint, joint_entity);
    });
    let id = joint_entity.raw_value();

    let Some(EditorInspectorFieldValue::EntityReference {
        binding: endpoint_a,
        options: options_a,
    }) = field(&adapter, id, "constraint", "joint-entity-a")
    else {
        panic!("expected joint endpoint A");
    };
    let Some(EditorInspectorFieldValue::EntityReference {
        options: options_b, ..
    }) = field(&adapter, id, "constraint", "joint-entity-b")
    else {
        panic!("expected joint endpoint B");
    };
    let option_ids: Vec<u64> = options_a.iter().map(|option| option.id).collect();
    let mut sorted = option_ids.clone();
    sorted.sort_unstable();
    assert_eq!(option_ids, sorted);
    let option_set: std::collections::BTreeSet<u64> = option_ids.iter().copied().collect();
    assert!(option_set.is_superset(&std::collections::BTreeSet::from([
        body_a.raw_value(),
        body_b.raw_value(),
        body_c.raw_value()
    ])));
    assert!(!option_ids.contains(&joint_entity.raw_value()));
    assert_eq!(options_b, options_a);
    endpoint_a.set(body_b.raw_value());
    assert_eq!(
        adapter
            .scene()
            .component::<PhysicsJoint>(joint_entity)
            .map(|joint| joint.entity_a),
        Some(body_a)
    );
    endpoint_a.set(body_c.raw_value());
    assert_eq!(
        adapter
            .scene()
            .component::<PhysicsJoint>(joint_entity)
            .map(|joint| joint.entity_a),
        Some(body_c)
    );

    let Some(EditorInspectorFieldValue::StringOptions { binding: kind, .. }) =
        field(&adapter, id, "constraint", "joint-type")
    else {
        panic!("expected joint type");
    };
    let Some(EditorInspectorFieldValue::Vector3 {
        x: axis_x,
        y: axis_y,
        z: axis_z,
    }) = field(&adapter, id, "constraint", "joint-axis-a")
    else {
        panic!("expected axis");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: minimum_angle,
        ..
    }) = field(&adapter, id, "constraint", "joint-minimum-angle")
    else {
        panic!("expected minimum angle");
    };
    let Some(EditorInspectorFieldValue::StringOptions {
        binding: motor_mode,
        ..
    }) = field(&adapter, id, "constraint", "joint-motor-mode")
    else {
        panic!("expected motor mode");
    };
    let Some(EditorInspectorFieldValue::Number(target_velocity)) =
        field(&adapter, id, "constraint", "joint-motor-target-velocity")
    else {
        panic!("expected target velocity");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: spring_damping,
        ..
    }) = field(&adapter, id, "constraint", "joint-spring-damping")
    else {
        panic!("expected spring damping");
    };

    axis_x.set(0.0);
    axis_y.set(0.0);
    axis_z.set(1.0);
    minimum_angle.set(-0.25);
    motor_mode.set(PhysicsJointMotorMode::Position.inspector_option_id());
    target_velocity.set(6.0);
    spring_damping.set(0.8);

    let Some(PhysicsJointConfiguration::Hinge(edited_hinge)) = adapter
        .scene()
        .component::<PhysicsJoint>(joint_entity)
        .map(|joint| joint.configuration)
    else {
        panic!("expected edited hinge configuration");
    };
    assert_eq!(edited_hinge.axis_a, Float3::new(0.0, 0.0, 1.0));
    assert_eq!(edited_hinge.minimum_angle, -0.25);
    assert_eq!(edited_hinge.motor.mode, PhysicsJointMotorMode::Position);
    assert_eq!(edited_hinge.motor.target_velocity, 6.0);
    assert_eq!(edited_hinge.spring.damping, 0.8);

    kind.set(PhysicsJointKind::SixDof.inspector_option_id());
    let Some(EditorInspectorFieldValue::Vector3 {
        x: linear_min_x,
        y: linear_min_y,
        z: linear_min_z,
    }) = field(&adapter, id, "constraint", "joint-linear-minimum")
    else {
        panic!("expected SixDOF linear minimum");
    };
    let Some(EditorInspectorFieldValue::StringOptions {
        binding: angular_motor_mode,
        ..
    }) = field(&adapter, id, "constraint", "joint-angular-mode")
    else {
        panic!("expected SixDOF angular mode");
    };
    linear_min_x.set(-1.0);
    linear_min_y.set(-2.0);
    linear_min_z.set(-3.0);
    angular_motor_mode.set(PhysicsJointMotorMode::Velocity.inspector_option_id());

    let Some(PhysicsJointConfiguration::SixDof(six_dof)) = adapter
        .scene()
        .component::<PhysicsJoint>(joint_entity)
        .map(|joint| joint.configuration)
    else {
        panic!("expected SixDOF configuration");
    };
    assert_eq!(six_dof.linear_minimum, Float3::new(-1.0, -2.0, -3.0));
    assert_eq!(six_dof.angular_motor.mode, PhysicsJointMotorMode::Velocity);
    assert!(field(&adapter, id, "constraint", "joint-minimum-angle").is_none());
}

/// Soft-body and cloth inspector edits simulation, topology, and fixed points.
#[test]
fn soft_body_and_cloth_bindings() {
    use diffuse_scene::physics::soft_bodies::cloth::{Cloth, ClothBendType};
    use diffuse_scene::physics::soft_bodies::soft_body::SoftBody;

    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    assert!(adapter.add_component("softBody", id));
    assert!(adapter.add_component("cloth", id));
    assert!(has_section(&adapter, id, "soft-body"));
    assert!(has_section(&adapter, id, "cloth"));

    let Some(EditorInspectorFieldValue::Bool(enabled)) =
        field(&adapter, id, "soft-body", "soft-body-enabled")
    else {
        panic!("expected enabled");
    };
    let Some(EditorInspectorFieldValue::Bool(self_collision)) =
        field(&adapter, id, "soft-body", "soft-body-self-collision")
    else {
        panic!("expected self collision");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: pressure, ..
    }) = field(&adapter, id, "soft-body", "soft-body-pressure")
    else {
        panic!("expected pressure");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: iterations,
        ..
    }) = field(&adapter, id, "soft-body", "soft-body-iterations")
    else {
        panic!("expected iterations");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: grid_x, ..
    }) = field(&adapter, id, "cloth", "cloth-grid-x")
    else {
        panic!("expected grid x");
    };
    let Some(EditorInspectorFieldValue::Json {
        binding: fixed_vertices,
        ..
    }) = field(&adapter, id, "cloth", "cloth-fixed-vertices")
    else {
        panic!("expected fixed vertices");
    };
    let Some(EditorInspectorFieldValue::StringOptions {
        binding: bend_type, ..
    }) = field(&adapter, id, "cloth", "cloth-bend-type")
    else {
        panic!("expected bend type");
    };

    enabled.set(false);
    self_collision.set(true);
    pressure.set(2.5);
    iterations.set(11.0);
    grid_x.set(6.0);
    fixed_vertices.set("[0,2,5,999]".to_string());
    bend_type.set("dihedral".to_string());

    let soft_body = adapter
        .scene()
        .component::<SoftBody>(entity)
        .expect("soft body");
    let cloth = adapter.scene().component::<Cloth>(entity).expect("cloth");
    assert!(!soft_body.is_enabled);
    assert!(soft_body.self_collision);
    assert_eq!(soft_body.pressure, 2.5);
    assert_eq!(soft_body.solver_iterations, 11);
    assert_eq!(cloth.grid_size_x, 6);
    assert_eq!(cloth.fixed_vertex_indices, vec![0, 2, 5]);
    assert_eq!(cloth.bend_type, ClothBendType::Dihedral);

    assert!(adapter.remove_component("cloth", id));
    assert!(adapter.remove_component("softBody", id));
    assert!(!has_section(&adapter, id, "cloth"));
    assert!(!has_section(&adapter, id, "soft-body"));
}

/// Surface soft-body inspector edits asset topology and excludes cloth.
#[test]
fn soft_body_mesh_bindings() {
    use std::collections::BTreeMap;

    use diffuse_math::simd::simd_compat::{Float2, Float3};
    use diffuse_scene::physics::queries::spatial_queries::{
        MeshColliderGeometry, MeshColliderGeometryResource,
    };
    use diffuse_scene::physics::soft_bodies::cloth::ClothBendType;
    use diffuse_scene::physics::soft_bodies::soft_body::SoftBodyMesh;
    use diffuse_scene::scene_bootstrap::AssetReferenceComponent;

    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    adapter.with_scene_mut(|scene| {
        scene.set_component(
            AssetReferenceComponent::new(
                "mesh-12",
                "Tetra",
                "Tetra.glb",
                "/tmp/Tetra.glb",
                "model",
                12,
            ),
            entity,
        );
        scene.set_resource(MeshColliderGeometryResource::new(
            BTreeMap::from([(
                "meshIndex:12".to_string(),
                MeshColliderGeometry::new(
                    vec![
                        Float3::ZERO,
                        Float3::new(1.0, 0.0, 0.0),
                        Float3::new(0.0, 1.0, 0.0),
                        Float3::new(0.0, 0.0, 1.0),
                    ],
                    vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
                    vec![0, 1, 2, 3],
                    Vec::<Float2>::new(),
                    None,
                    0,
                ),
            )]),
            None,
        ));
    });

    assert!(adapter.add_component("softBody", id));
    assert!(adapter.add_component("softBodyMesh", id));
    assert!(has_section(&adapter, id, "soft-body-mesh"));
    assert!(
        !adapter
            .addable_component_schemas(id)
            .iter()
            .any(|schema| schema.type_id == "cloth")
    );
    assert!(!adapter.add_component("cloth", id));

    let Some(EditorInspectorFieldValue::Text(resource)) =
        field(&adapter, id, "soft-body-mesh", "soft-body-mesh-resource")
    else {
        panic!("expected resource");
    };
    let Some(EditorInspectorFieldValue::Json {
        binding: fixed_vertices,
        ..
    }) = field(&adapter, id, "soft-body-mesh", "soft-body-mesh-fixed")
    else {
        panic!("expected fixed vertices");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: compliance,
        ..
    }) = field(&adapter, id, "soft-body-mesh", "soft-body-mesh-compliance")
    else {
        panic!("expected compliance");
    };
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: volume_compliance,
        ..
    }) = field(&adapter, id, "soft-body-mesh", "soft-body-mesh-volume")
    else {
        panic!("expected volume compliance");
    };
    let Some(EditorInspectorFieldValue::StringOptions {
        binding: bend_type, ..
    }) = field(&adapter, id, "soft-body-mesh", "soft-body-mesh-bend-type")
    else {
        panic!("expected bend type");
    };
    let Some(EditorInspectorFieldValue::ReadOnly(tetrahedron_count)) =
        field(&adapter, id, "soft-body-mesh", "soft-body-mesh-tetrahedra")
    else {
        panic!("expected tetrahedra");
    };

    assert_eq!(resource.get(), "meshIndex:12");
    assert_eq!(tetrahedron_count, "1");
    resource.set("soft.tetra".to_string());
    fixed_vertices.set("[7,2,-1,2]".to_string());
    compliance.set(0.006);
    volume_compliance.set(0.002);
    bend_type.set("distance".to_string());

    let mesh = adapter
        .scene()
        .component::<SoftBodyMesh>(entity)
        .expect("soft body mesh");
    assert_eq!(mesh.resource_id.as_deref(), Some("soft.tetra"));
    assert_eq!(mesh.fixed_vertex_indices, vec![2, 7]);
    assert_eq!(mesh.compliance, 0.006);
    assert_eq!(mesh.volume_compliance, 0.002);
    assert_eq!(mesh.bend_type, ClothBendType::Distance);

    assert!(adapter.remove_component("softBodyMesh", id));
    assert!(!has_section(&adapter, id, "soft-body-mesh"));
    assert!(
        adapter
            .addable_component_schemas(id)
            .iter()
            .any(|schema| schema.type_id == "cloth")
    );
}

/// Particle emitter section appears with the component.
#[test]
fn particle_section_presence() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(!has_section(&adapter, id, "particle-emitter"));
    assert!(has_section(&adapter, id, "particle-scalability"));
    assert!(adapter.add_component("particleEmitter", id));
    assert!(has_section(&adapter, id, "particle-emitter"));
}

/// Particle inspector exposes the module stack.
#[test]
fn particle_module_stack_field() {
    use diffuse_scene::particles::particle_modules::ParticleModuleStack;

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let Some(EditorInspectorFieldValue::ParticleModuleStack(binding)) =
        field(&adapter, id, "particle-emitter", "particle-module-stack")
    else {
        panic!("expected particle module stack field");
    };
    let stack = binding.get();
    assert_eq!(stack.version, ParticleModuleStack::CURRENT_VERSION);
    let ids: Vec<String> = stack
        .modules
        .iter()
        .map(|module| module.id.clone())
        .collect();
    assert_eq!(
        ids,
        [
            "emission",
            "shape",
            "velocity",
            "forces",
            "collision",
            "appearance",
            "textureSheet",
            "renderer",
            "trails",
            "subEmitters",
            "gpuSimulation"
        ]
    );
}

/// Particle module stack binding preserves disabled module authoring state.
#[test]
fn particle_module_stack_binding_preserves_disabled_module_authoring_state() {
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::particle_modules::ParticleEmitterModuleSettings;

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);

    let Some(EditorInspectorFieldValue::ParticleModuleStack(binding)) =
        field(&adapter, id, "particle-emitter", "particle-module-stack")
    else {
        panic!("expected particle module stack field");
    };
    let mut stack = binding.get();
    let forces_index = stack
        .modules
        .iter()
        .position(|module| module.id == "forces")
        .expect("forces module");
    stack.modules[forces_index].is_enabled = false;
    if let ParticleEmitterModuleSettings::Forces(mut settings) =
        stack.modules[forces_index].settings.clone()
    {
        settings.gravity.y = -7.0;
        stack.modules[forces_index].settings = ParticleEmitterModuleSettings::Forces(settings);
    } else {
        panic!("expected forces module settings");
    }
    binding.set(stack);

    let stored_stack = adapter
        .scene()
        .component::<ParticleEmitter>(entity)
        .expect("emitter")
        .module_stack();
    let forces = stored_stack
        .modules
        .iter()
        .find(|module| module.id == "forces")
        .expect("forces module");
    assert!(!forces.is_enabled);
    let ParticleEmitterModuleSettings::Forces(settings) = &forces.settings else {
        panic!("expected forces module settings");
    };
    assert_eq!(settings.gravity.y, -7.0);

    let Some(EditorInspectorFieldValue::Vector3 { y: gravity_y, .. }) =
        field(&adapter, id, "particle-emitter", "particle-gravity")
    else {
        panic!("missing gravity field");
    };
    gravity_y.set(-3.0);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.forces.gravity.y),
        Some(-3.0)
    );
    let rebased_stack = adapter
        .scene()
        .component::<ParticleEmitter>(entity)
        .expect("emitter")
        .module_stack();
    let rebased_forces = rebased_stack
        .modules
        .iter()
        .find(|module| module.id == "forces")
        .expect("forces module");
    assert!(!rebased_forces.is_enabled);
    let ParticleEmitterModuleSettings::Forces(settings) = &rebased_forces.settings else {
        panic!("expected forces module settings");
    };
    assert_eq!(settings.gravity.y, -7.0);
}

/// Particle module stack binding writes order and reset state.
#[test]
fn particle_module_stack_binding_writes_order_and_reset_state() {
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::particle_modules::ParticleModuleStack;

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);

    let Some(EditorInspectorFieldValue::ParticleModuleStack(binding)) =
        field(&adapter, id, "particle-emitter", "particle-module-stack")
    else {
        panic!("expected particle module stack field");
    };
    let mut moved = binding.get();
    let renderer_index = moved
        .modules
        .iter()
        .position(|module| module.id == "renderer")
        .expect("renderer module");
    moved.move_module(renderer_index, 0);
    moved.modules[0].is_enabled = false;
    binding.set(moved);

    let mut stored = adapter
        .scene()
        .component::<ParticleEmitter>(entity)
        .expect("emitter")
        .module_stack();
    assert_eq!(
        stored.modules.first().map(|module| module.id.as_str()),
        Some("renderer")
    );
    assert_eq!(
        stored.modules.first().map(|module| module.is_enabled),
        Some(false)
    );
    stored.reset_authoring_state();
    binding.set(stored);

    let reset = adapter
        .scene()
        .component::<ParticleEmitter>(entity)
        .expect("emitter")
        .module_stack();
    let ids: Vec<String> = reset
        .modules
        .iter()
        .map(|module| module.id.clone())
        .collect();
    assert_eq!(ids, ParticleModuleStack::DEFAULT_MODULE_IDS);
    assert!(reset.modules.iter().all(|module| module.is_enabled));
    assert!(reset.modules.iter().all(|module| !module.is_expanded));
}

/// Particle module stack binding writes single module default reset.
#[test]
fn particle_module_stack_binding_writes_single_module_default_reset() {
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::particle_modules::ParticleEmitterModuleSettings;
    use diffuse_scene::particles::particle_types::{ParticleRenderBoundsMode, ParticleRenderMode};

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);

    let Some(EditorInspectorFieldValue::ParticleModuleStack(binding)) =
        field(&adapter, id, "particle-emitter", "particle-module-stack")
    else {
        panic!("expected particle module stack field");
    };
    let mut stack = binding.get();
    let renderer_index = stack
        .modules
        .iter()
        .position(|module| module.id == "renderer")
        .expect("renderer module");
    stack.modules[renderer_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Renderer(mut module) =
        stack.modules[renderer_index].settings.clone()
    {
        module.render_mode = ParticleRenderMode::Ribbon;
        module.render_sort_priority = 9;
        module.render_bounds_mode = ParticleRenderBoundsMode::Manual;
        module.render_bounds_radius = 12.0;
        stack.modules[renderer_index].settings = ParticleEmitterModuleSettings::Renderer(module);
    } else {
        panic!("expected renderer module settings");
    }
    binding.set(stack);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.renderer.render_mode),
        Some(ParticleRenderMode::Ribbon)
    );

    let mut stored = adapter
        .scene()
        .component::<ParticleEmitter>(entity)
        .expect("emitter")
        .module_stack();
    assert!(stored.module_settings_differ_from_default("renderer"));
    stored.reset_module_settings("renderer");
    binding.set(stored);

    let reset_emitter = adapter
        .scene()
        .component::<ParticleEmitter>(entity)
        .expect("emitter");
    let reset_stack = reset_emitter.module_stack();
    let reset_renderer = reset_stack
        .modules
        .iter()
        .find(|module| module.id == "renderer")
        .expect("renderer module");
    assert_eq!(
        reset_emitter.settings.renderer.render_mode,
        ParticleRenderMode::Billboard
    );
    assert_eq!(reset_emitter.settings.renderer.render_sort_priority, 0);
    assert_eq!(
        reset_emitter.settings.renderer.render_bounds_mode,
        ParticleRenderBoundsMode::Disabled
    );
    assert!(reset_renderer.is_expanded);
    assert!(!reset_stack.module_settings_differ_from_default("renderer"));
}

/// Particle module stack binding writes inline module settings.
#[test]
fn particle_module_stack_binding_writes_inline_module_settings() {
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::particle_curve::{ParticleCurve, ParticleCurveKeyframe};
    use diffuse_scene::particles::particle_events::ParticleSubEmitter;
    use diffuse_scene::particles::particle_modules::ParticleEmitterModuleSettings;
    use diffuse_scene::particles::particle_types::{
        ParticleBlendMode, ParticleCollisionMode, ParticleEmissionShape, ParticleForceMode,
        ParticleRenderAlignment, ParticleRenderBoundsMode, ParticleRenderMode,
        ParticleSimulationBackend, ParticleSimulationSpace, ParticleSortMode,
        ParticleSubEmitterTrigger, ParticleTextureSheetPlaybackMode, ParticleVectorFieldMode,
    };

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);

    let Some(EditorInspectorFieldValue::ParticleModuleStack(binding)) =
        field(&adapter, id, "particle-emitter", "particle-module-stack")
    else {
        panic!("expected particle module stack field");
    };
    let mut stack = binding.get();
    let emission_index = stack
        .modules
        .iter()
        .position(|module| module.id == "emission")
        .expect("emission module");
    stack.modules[emission_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Emission(module) =
        &mut stack.modules[emission_index].settings
    {
        module.emission_rate = 77.0;
        module.max_particles = 512;
        module.max_spawned_particles_per_frame = 96;
        module.simulation_speed = 1.75;
        module.distance_emission_rate = 9.0;
        module.emission_rate_curve = ParticleCurve::EaseInOut;
        module.distance_emission_rate_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.25),
            ParticleCurveKeyframe::new(1.0, 1.5),
        ]);
        module.burst_interval = 0.25;
        module.seed = 123_456_789;
    } else {
        panic!("expected emission module settings");
    }

    let shape_index = stack
        .modules
        .iter()
        .position(|module| module.id == "shape")
        .expect("shape module");
    stack.modules[shape_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Shape(module) = &mut stack.modules[shape_index].settings {
        module.emission_shape = ParticleEmissionShape::Cone;
        module.origin_offset = Float3::new(0.5, 1.5, -2.5);
        module.spawn_radius = 2.25;
        module.box_half_extents = Float3::new(4.0, 5.0, 6.0);
        module.cone_radius = 3.5;
        module.cone_height = 7.0;
    } else {
        panic!("expected shape module settings");
    }

    let forces_index = stack
        .modules
        .iter()
        .position(|module| module.id == "forces")
        .expect("forces module");
    stack.modules[forces_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Forces(module) = &mut stack.modules[forces_index].settings
    {
        module.force_mode = ParticleForceMode::Radial;
        module.vector_field_mode = ParticleVectorFieldMode::Curl;
        module.gravity = Float3::new(1.0, -4.0, 2.0);
        module.noise_strength = 2.5;
        module.noise_scale = 1.75;
        module.noise_speed = 0.6;
        module.force_center = Float3::new(3.0, 4.0, 5.0);
        module.force_radius = 11.0;
        module.force_falloff = 1.5;
        module.vector_field_strength = 8.5;
        module.vector_field_scale = 3.0;
        module.vector_field_scroll_speed = 0.75;
    } else {
        panic!("expected forces module settings");
    }

    let velocity_index = stack
        .modules
        .iter()
        .position(|module| module.id == "velocity")
        .expect("velocity module");
    stack.modules[velocity_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Velocity(module) =
        &mut stack.modules[velocity_index].settings
    {
        module.start_velocity = Float3::new(1.0, 2.0, 3.0);
        module.velocity_randomness = Float3::new(0.25, 0.5, 0.75);
        module.velocity_inheritance = 0.4;
    } else {
        panic!("expected velocity module settings");
    }

    let collision_index = stack
        .modules
        .iter()
        .position(|module| module.id == "collision")
        .expect("collision module");
    stack.modules[collision_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Collision(module) =
        &mut stack.modules[collision_index].settings
    {
        module.collision_mode = ParticleCollisionMode::WorldPlane;
        module.collision_plane_y = -2.0;
        module.collision_restitution = 0.8;
        module.collision_damping = 0.35;
    } else {
        panic!("expected collision module settings");
    }
    let appearance_index = stack
        .modules
        .iter()
        .position(|module| module.id == "appearance")
        .expect("appearance module");
    stack.modules[appearance_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Appearance(module) =
        &mut stack.modules[appearance_index].settings
    {
        module.blend_mode = ParticleBlendMode::Additive;
        module.lifetime = 2.5;
        module.lifetime_randomness = 0.4;
        module.start_size = 1.2;
        module.end_size = 0.3;
        module.size_randomness = 0.25;
        module.size_curve = ParticleCurve::EaseOut;
        module.start_color = Float4::new(0.9, 0.25, 0.1, 0.8);
        module.end_color = Float4::new(0.1, 0.35, 1.0, 0.2);
        module.color_curve = ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(0.65, 0.9),
            ParticleCurveKeyframe::new(1.0, 1.0),
        ]);
        module.start_rotation = 15.0;
        module.rotation_randomness = 45.0;
        module.angular_velocity = 120.0;
        module.angular_velocity_randomness = 30.0;
    } else {
        panic!("expected appearance module settings");
    }

    let texture_sheet_index = stack
        .modules
        .iter()
        .position(|module| module.id == "textureSheet")
        .expect("texture sheet module");
    stack.modules[texture_sheet_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::TextureSheet(module) =
        &mut stack.modules[texture_sheet_index].settings
    {
        module.playback_mode = ParticleTextureSheetPlaybackMode::Loop;
        module.frame_rate = 24.0;
        module.columns = 4;
        module.rows = 2;
        module.frame_count = 8;
        module.start_frame = 2;
        module.frame_randomness = 3;
    } else {
        panic!("expected texture sheet module settings");
    }

    let renderer_index = stack
        .modules
        .iter()
        .position(|module| module.id == "renderer")
        .expect("renderer module");
    stack.modules[renderer_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Renderer(module) =
        &mut stack.modules[renderer_index].settings
    {
        module.render_mode = ParticleRenderMode::Ribbon;
        module.sort_mode = ParticleSortMode::OldestFirst;
        module.render_sort_priority = 12;
        module.render_alignment = ParticleRenderAlignment::Velocity;
        module.render_bounds_mode = ParticleRenderBoundsMode::Manual;
        module.max_render_distance = 123.0;
        module.render_distance_fade_range = 9.0;
        module.render_lod_start_distance = 30.0;
        module.render_lod_end_distance = 120.0;
        module.render_lod_min_particle_scale = 0.35;
        module.render_bounds_radius = 42.0;
        module.velocity_stretch_scale = 0.5;
        module.velocity_stretch_max = 9.0;
    } else {
        panic!("expected renderer module settings");
    }

    let trails_index = stack
        .modules
        .iter()
        .position(|module| module.id == "trails")
        .expect("trails module");
    stack.modules[trails_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::Trails(module) = &mut stack.modules[trails_index].settings
    {
        module.trail_length = 1.25;
        module.trail_segments = 7;
        module.trail_end_alpha_scale = 0.3;
        module.ribbon_width_scale = 1.6;
        module.ribbon_tail_width_scale = 0.2;
        module.ribbon_tail_alpha_scale = 0.4;
        module.ribbon_max_segment_length = 5.0;
        module.ribbon_join_overlap_scale = 0.15;
        module.ribbon_smoothing_segments = 4;
        module.ribbon_texture_tiling = 4.0;
        module.ribbon_texture_offset = 0.75;
        module.trail_end_size_scale = 0.45;
    } else {
        panic!("expected trails module settings");
    }

    let sub_emitters_index = stack
        .modules
        .iter()
        .position(|module| module.id == "subEmitters")
        .expect("sub emitters module");
    stack.modules[sub_emitters_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::SubEmitters(module) =
        &mut stack.modules[sub_emitters_index].settings
    {
        module.legacy_trigger = ParticleSubEmitterTrigger::Collision;
        module.legacy_burst_count = 3;
        module.legacy_probability = 0.6;
        module.legacy_max_depth = 2;
        module.legacy_inherit_velocity = 0.25;
        module.legacy_lifetime = 1.75;
        module.rules = vec![ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::Death,
            5,
            0.75,
            3,
            0.5,
            0.9,
            Float3::new(0.0, 2.0, 0.0),
            Float3::new(0.1, 0.2, 0.3),
            0.4,
            0.1,
            Float4::new(1.0, 0.5, 0.25, 1.0),
            Float4::new(1.0, 0.1, 0.0, 0.0),
        )];
    } else {
        panic!("expected sub emitters module settings");
    }

    let gpu_index = stack
        .modules
        .iter()
        .position(|module| module.id == "gpuSimulation")
        .expect("gpu simulation module");
    stack.modules[gpu_index].is_expanded = true;
    if let ParticleEmitterModuleSettings::GpuSimulation(module) =
        &mut stack.modules[gpu_index].settings
    {
        module.simulation_space = ParticleSimulationSpace::World;
        module.simulation_backend = ParticleSimulationBackend::GpuIfSupported;
        module.workgroup_size = 96;
    } else {
        panic!("expected gpu simulation module settings");
    }

    binding.set(stack);
    let emitter = adapter
        .scene()
        .component::<ParticleEmitter>(entity)
        .expect("emitter");
    assert_eq!(emitter.settings.emission.emission_rate, 77.0);
    assert_eq!(emitter.settings.emission.max_particles, 512);
    assert_eq!(
        emitter.settings.emission.max_spawned_particles_per_frame,
        96
    );
    assert_eq!(emitter.settings.emission.simulation_speed, 1.75);
    assert_eq!(emitter.settings.emission.distance_emission_rate, 9.0);
    assert_eq!(
        emitter.settings.emission.emission_rate_curve,
        ParticleCurve::EaseInOut
    );
    assert_eq!(
        emitter.settings.emission.distance_emission_rate_curve,
        ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.25),
            ParticleCurveKeyframe::new(1.0, 1.5),
        ])
    );
    assert_eq!(emitter.settings.emission.burst_interval, 0.25);
    assert_eq!(emitter.settings.emission.seed, 123_456_789);
    assert_eq!(
        emitter.settings.shape.emission_shape,
        ParticleEmissionShape::Cone
    );
    assert_eq!(
        emitter.settings.shape.origin_offset,
        Float3::new(0.5, 1.5, -2.5)
    );
    assert_eq!(emitter.settings.shape.spawn_radius, 2.25);
    assert_eq!(
        emitter.settings.shape.box_half_extents,
        Float3::new(4.0, 5.0, 6.0)
    );
    assert_eq!(emitter.settings.shape.cone_radius, 3.5);
    assert_eq!(emitter.settings.shape.cone_height, 7.0);
    assert_eq!(
        emitter.settings.forces.force_mode,
        ParticleForceMode::Radial
    );
    assert_eq!(
        emitter.settings.forces.vector_field_mode,
        ParticleVectorFieldMode::Curl
    );
    assert_eq!(emitter.settings.forces.gravity, Float3::new(1.0, -4.0, 2.0));
    assert_eq!(emitter.settings.forces.noise_strength, 2.5);
    assert_eq!(emitter.settings.forces.noise_scale, 1.75);
    assert_eq!(emitter.settings.forces.noise_speed, 0.6);
    assert_eq!(
        emitter.settings.forces.force_center,
        Float3::new(3.0, 4.0, 5.0)
    );
    assert_eq!(emitter.settings.forces.force_radius, 11.0);
    assert_eq!(emitter.settings.forces.force_falloff, 1.5);
    assert_eq!(emitter.settings.forces.vector_field_strength, 8.5);
    assert_eq!(emitter.settings.forces.vector_field_scale, 3.0);
    assert_eq!(emitter.settings.forces.vector_field_scroll_speed, 0.75);
    assert_eq!(
        emitter.settings.velocity.start_velocity,
        Float3::new(1.0, 2.0, 3.0)
    );
    assert_eq!(
        emitter.settings.velocity.velocity_randomness,
        Float3::new(0.25, 0.5, 0.75)
    );
    assert_eq!(emitter.settings.velocity.velocity_inheritance, 0.4);
    assert_eq!(
        emitter.settings.collision.collision_mode,
        ParticleCollisionMode::WorldPlane
    );
    assert_eq!(emitter.settings.collision.collision_plane_y, -2.0);
    assert_eq!(emitter.settings.collision.collision_restitution, 0.8);
    assert_eq!(emitter.settings.collision.collision_damping, 0.35);
    assert_eq!(
        emitter.settings.appearance.blend_mode,
        ParticleBlendMode::Additive
    );
    assert_eq!(emitter.settings.appearance.lifetime, 2.5);
    assert_eq!(emitter.settings.appearance.lifetime_randomness, 0.4);
    assert_eq!(emitter.settings.appearance.start_size, 1.2);
    assert_eq!(emitter.settings.appearance.end_size, 0.3);
    assert_eq!(emitter.settings.appearance.size_randomness, 0.25);
    assert_eq!(
        emitter.settings.appearance.size_curve,
        ParticleCurve::EaseOut
    );
    assert_eq!(
        emitter.settings.appearance.start_color,
        Float4::new(0.9, 0.25, 0.1, 0.8)
    );
    assert_eq!(
        emitter.settings.appearance.end_color,
        Float4::new(0.1, 0.35, 1.0, 0.2)
    );
    assert_eq!(
        emitter.settings.appearance.color_curve,
        ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(0.65, 0.9),
            ParticleCurveKeyframe::new(1.0, 1.0),
        ])
    );
    assert_eq!(emitter.settings.appearance.start_rotation, 15.0);
    assert_eq!(emitter.settings.appearance.rotation_randomness, 45.0);
    assert_eq!(emitter.settings.appearance.angular_velocity, 120.0);
    assert_eq!(
        emitter.settings.appearance.angular_velocity_randomness,
        30.0
    );
    assert_eq!(
        emitter.settings.texture_sheet.playback_mode,
        ParticleTextureSheetPlaybackMode::Loop
    );
    assert_eq!(emitter.settings.texture_sheet.frame_rate, 24.0);
    assert_eq!(emitter.settings.texture_sheet.columns, 4);
    assert_eq!(emitter.settings.texture_sheet.rows, 2);
    assert_eq!(emitter.settings.texture_sheet.frame_count, 8);
    assert_eq!(emitter.settings.texture_sheet.start_frame, 2);
    assert_eq!(emitter.settings.texture_sheet.frame_randomness, 3);
    assert_eq!(
        emitter.settings.renderer.render_mode,
        ParticleRenderMode::Ribbon
    );
    assert_eq!(
        emitter.settings.renderer.sort_mode,
        ParticleSortMode::OldestFirst
    );
    assert_eq!(emitter.settings.renderer.render_sort_priority, 12);
    assert_eq!(
        emitter.settings.renderer.render_alignment,
        ParticleRenderAlignment::Velocity
    );
    assert_eq!(
        emitter.settings.renderer.render_bounds_mode,
        ParticleRenderBoundsMode::Manual
    );
    assert_eq!(emitter.settings.renderer.max_render_distance, 123.0);
    assert_eq!(emitter.settings.renderer.render_distance_fade_range, 9.0);
    assert_eq!(emitter.settings.renderer.render_lod_start_distance, 30.0);
    assert_eq!(emitter.settings.renderer.render_lod_end_distance, 120.0);
    assert_eq!(
        emitter.settings.renderer.render_lod_min_particle_scale,
        0.35
    );
    assert_eq!(emitter.settings.renderer.render_bounds_radius, 42.0);
    assert_eq!(emitter.settings.renderer.velocity_stretch_scale, 0.5);
    assert_eq!(emitter.settings.renderer.velocity_stretch_max, 9.0);
    assert_eq!(emitter.settings.trails.trail_length, 1.25);
    assert_eq!(emitter.settings.trails.trail_segments, 7);
    assert_eq!(emitter.settings.trails.trail_end_alpha_scale, 0.3);
    assert_eq!(emitter.settings.trails.trail_end_size_scale, 0.45);
    assert_eq!(emitter.settings.trails.ribbon_width_scale, 1.6);
    assert_eq!(emitter.settings.trails.ribbon_tail_width_scale, 0.2);
    assert_eq!(emitter.settings.trails.ribbon_tail_alpha_scale, 0.4);
    assert_eq!(emitter.settings.trails.ribbon_max_segment_length, 5.0);
    assert_eq!(emitter.settings.trails.ribbon_join_overlap_scale, 0.15);
    assert_eq!(emitter.settings.trails.ribbon_smoothing_segments, 4);
    assert_eq!(emitter.settings.trails.ribbon_texture_tiling, 4.0);
    assert_eq!(emitter.settings.trails.ribbon_texture_offset, 0.75);
    assert_eq!(
        emitter.settings.sub_emitters.legacy_trigger,
        ParticleSubEmitterTrigger::Collision
    );
    assert_eq!(emitter.settings.sub_emitters.legacy_burst_count, 3);
    assert_eq!(emitter.settings.sub_emitters.legacy_probability, 0.6);
    assert_eq!(emitter.settings.sub_emitters.legacy_max_depth, 2);
    assert_eq!(emitter.settings.sub_emitters.legacy_inherit_velocity, 0.25);
    assert_eq!(emitter.settings.sub_emitters.legacy_lifetime, 1.75);
    assert_eq!(
        emitter.settings.sub_emitters.rules,
        vec![ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::Death,
            5,
            0.75,
            3,
            0.5,
            0.9,
            Float3::new(0.0, 2.0, 0.0),
            Float3::new(0.1, 0.2, 0.3),
            0.4,
            0.1,
            Float4::new(1.0, 0.5, 0.25, 1.0),
            Float4::new(1.0, 0.1, 0.0, 0.0),
        )]
    );
    assert_eq!(
        emitter.settings.gpu_simulation.simulation_space,
        ParticleSimulationSpace::World
    );
    assert_eq!(
        emitter.settings.gpu_simulation.simulation_backend,
        ParticleSimulationBackend::GpuIfSupported
    );
    assert_eq!(emitter.settings.gpu_simulation.workgroup_size, 96);

    let stored_stack = emitter.module_stack();
    for module_id in [
        "emission",
        "shape",
        "forces",
        "velocity",
        "collision",
        "appearance",
        "textureSheet",
        "renderer",
        "trails",
        "subEmitters",
        "gpuSimulation",
    ] {
        assert_eq!(
            stored_stack
                .modules
                .iter()
                .find(|module| module.id == module_id)
                .map(|module| module.is_expanded),
            Some(true),
            "{module_id}"
        );
    }
}

/// Particle scalability bindings write scene resources.
#[test]
fn particle_scalability_bindings() {
    use diffuse_scene::particles::particle_scalability::{
        ParticleScalabilityPolicyResource, ParticleScalabilityResource,
    };

    let adapter = adapter();
    let id = make_entity(&adapter);

    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: emission_scale,
        ..
    }) = field(
        &adapter,
        id,
        "particle-scalability",
        "particle-scale-emission",
    )
    else {
        panic!("expected emission scale field");
    };
    emission_scale.set(0.5);
    assert_eq!(
        adapter
            .scene()
            .resource::<ParticleScalabilityResource>()
            .map(|resource| resource.emission_scale),
        Some(0.5)
    );

    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: live_cap_scale,
        ..
    }) = field(
        &adapter,
        id,
        "particle-scalability",
        "particle-scale-live-cap",
    )
    else {
        panic!("expected live cap scale field");
    };
    live_cap_scale.set(0.25);
    assert_eq!(
        adapter
            .scene()
            .resource::<ParticleScalabilityResource>()
            .map(|resource| resource.max_live_particle_scale),
        Some(0.25)
    );

    let Some(EditorInspectorFieldValue::Bool(enabled)) = field(
        &adapter,
        id,
        "particle-scalability",
        "particle-policy-enabled",
    ) else {
        panic!("expected policy enabled field");
    };
    enabled.set(true);
    assert_eq!(
        adapter
            .scene()
            .resource::<ParticleScalabilityPolicyResource>()
            .map(|resource| resource.is_enabled),
        Some(true)
    );

    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: target_live,
        ..
    }) = field(
        &adapter,
        id,
        "particle-scalability",
        "particle-policy-target-live",
    )
    else {
        panic!("expected target live field");
    };
    target_live.set(12_345.0);
    assert_eq!(
        adapter
            .scene()
            .resource::<ParticleScalabilityPolicyResource>()
            .map(|resource| resource.target_live_particles),
        Some(12_345)
    );

    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: minimum_scale,
        ..
    }) = field(
        &adapter,
        id,
        "particle-scalability",
        "particle-policy-min-scale",
    )
    else {
        panic!("expected minimum scale field");
    };
    minimum_scale.set(1.5);
    assert_eq!(
        adapter
            .scene()
            .resource::<ParticleScalabilityPolicyResource>()
            .map(|resource| resource.minimum_scale),
        Some(1.0)
    );
}

/// Particle gravity vector and color bindings write back.
#[test]
fn particle_gravity_vector_and_color_bindings() {
    use cove_ui_compose::scene_core::Color;
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);

    let Some(EditorInspectorFieldValue::Vector3 {
        x: gx,
        y: gy,
        z: gz,
    }) = field(&adapter, id, "particle-emitter", "particle-gravity")
    else {
        panic!("expected gravity vector");
    };
    gx.set(1.0);
    gy.set(-20.0);
    gz.set(3.0);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.forces.gravity),
        Some(Float3::new(1.0, -20.0, 3.0))
    );

    let Some(EditorInspectorFieldValue::Vector3 {
        x: bx,
        y: by,
        z: bz,
    }) = field(&adapter, id, "particle-emitter", "particle-box-extents")
    else {
        panic!("expected box extents vector");
    };
    bx.set(2.0);
    by.set(3.0);
    bz.set(4.0);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.shape.box_half_extents),
        Some(Float3::new(2.0, 3.0, 4.0))
    );

    let Some(EditorInspectorFieldValue::Vector3 {
        x: fcx,
        y: fcy,
        z: fcz,
    }) = field(&adapter, id, "particle-emitter", "particle-force-center")
    else {
        panic!("expected force center vector");
    };
    fcx.set(1.0);
    fcy.set(2.0);
    fcz.set(3.0);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.forces.force_center),
        Some(Float3::new(1.0, 2.0, 3.0))
    );

    let Some(EditorInspectorFieldValue::Vector3 {
        x: fax,
        y: fay,
        z: faz,
    }) = field(&adapter, id, "particle-emitter", "particle-force-axis")
    else {
        panic!("expected force axis vector");
    };
    fax.set(0.0);
    fay.set(1.0);
    faz.set(0.0);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.forces.force_axis),
        Some(Float3::new(0.0, 1.0, 0.0))
    );

    let Some(EditorInspectorFieldValue::Vector3 {
        x: svx,
        y: svy,
        z: svz,
    }) = field(
        &adapter,
        id,
        "particle-emitter",
        "particle-sub-emitter-velocity",
    )
    else {
        panic!("expected sub-emitter velocity vector");
    };
    svx.set(1.0);
    svy.set(2.0);
    svz.set(3.0);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.sub_emitters.legacy_start_velocity),
        Some(Float3::new(1.0, 2.0, 3.0))
    );

    let Some(EditorInspectorFieldValue::Vector3 {
        x: srx,
        y: sry,
        z: srz,
    }) = field(
        &adapter,
        id,
        "particle-emitter",
        "particle-sub-emitter-velocity-random",
    )
    else {
        panic!("expected sub-emitter velocity random vector");
    };
    srx.set(0.1);
    sry.set(0.2);
    srz.set(0.3);
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.sub_emitters.legacy_velocity_randomness),
        Some(Float3::new(0.1, 0.2, 0.3))
    );

    let Some(EditorInspectorFieldValue::Color(sub_start)) = field(
        &adapter,
        id,
        "particle-emitter",
        "particle-sub-emitter-start-color",
    ) else {
        panic!("expected sub-emitter start color");
    };
    sub_start.set(Color {
        r: 1.0,
        g: 0.5,
        b: 0.0,
        a: 1.0,
    });
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.sub_emitters.legacy_start_color),
        Some(Float4::new(1.0, 0.5, 0.0, 1.0))
    );

    let Some(EditorInspectorFieldValue::Color(sub_end)) = field(
        &adapter,
        id,
        "particle-emitter",
        "particle-sub-emitter-end-color",
    ) else {
        panic!("expected sub-emitter end color");
    };
    sub_end.set(Color {
        r: 1.0,
        g: 0.0,
        b: 0.0,
        a: 0.0,
    });
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.sub_emitters.legacy_end_color),
        Some(Float4::new(1.0, 0.0, 0.0, 0.0))
    );

    let Some(EditorInspectorFieldValue::Color(start)) =
        field(&adapter, id, "particle-emitter", "particle-start-color")
    else {
        panic!("expected start color");
    };
    start.set(Color {
        r: 1.0,
        g: 0.0,
        b: 0.0,
        a: 1.0,
    });
    assert_eq!(
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .map(|emitter| emitter.settings.appearance.start_color),
        Some(Float4::new(1.0, 0.0, 0.0, 1.0))
    );
}

/// Particle scalar and bool bindings write back.
#[test]
fn particle_scalar_bindings() {
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::particle_curve::{ParticleCurve, ParticleCurveKeyframe};
    use diffuse_scene::particles::particle_events::ParticleSubEmitter;
    use diffuse_scene::particles::particle_types::{
        ParticleBlendMode, ParticleCollisionMode, ParticleEmissionShape, ParticleForceMode,
        ParticleRenderAlignment, ParticleRenderBoundsMode, ParticleSimulationBackend,
        ParticleSimulationSpace, ParticleSubEmitterTrigger, ParticleTextureSheetPlaybackMode,
        ParticleVectorFieldMode,
    };

    use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

    fn emitter(
        adapter: &EditorSceneAdapter,
        entity: diffuse_scene::entity_id::EntityID,
    ) -> ParticleEmitter {
        adapter
            .scene()
            .component::<ParticleEmitter>(entity)
            .expect("particle emitter")
    }

    fn set_number(adapter: &EditorSceneAdapter, id: u64, field_id: &str, value: f32) -> bool {
        match field(adapter, id, "particle-emitter", field_id) {
            Some(EditorInspectorFieldValue::ConstrainedNumber { binding, .. }) => {
                binding.set(value);
                true
            }
            _ => false,
        }
    }

    fn set_bool(adapter: &EditorSceneAdapter, id: u64, field_id: &str, value: bool) -> bool {
        match field(adapter, id, "particle-emitter", field_id) {
            Some(EditorInspectorFieldValue::Bool(binding)) => {
                binding.set(value);
                true
            }
            _ => false,
        }
    }

    fn set_option(adapter: &EditorSceneAdapter, id: u64, field_id: &str, value: String) -> bool {
        match field(adapter, id, "particle-emitter", field_id) {
            Some(EditorInspectorFieldValue::StringOptions { binding, .. }) => {
                binding.set(value);
                true
            }
            _ => false,
        }
    }

    fn set_curve(
        adapter: &EditorSceneAdapter,
        id: u64,
        field_id: &str,
        value: ParticleCurve,
    ) -> bool {
        match field(adapter, id, "particle-emitter", field_id) {
            Some(EditorInspectorFieldValue::ParticleCurve(binding)) => {
                binding.set(value);
                true
            }
            _ => false,
        }
    }

    fn set_vector3(
        adapter: &EditorSceneAdapter,
        id: u64,
        field_id: &str,
        value: (f32, f32, f32),
    ) -> bool {
        match field(adapter, id, "particle-emitter", field_id) {
            Some(EditorInspectorFieldValue::Vector3 { x, y, z }) => {
                x.set(value.0);
                y.set(value.1);
                z.set(value.2);
                true
            }
            _ => false,
        }
    }

    fn set_sub_emitters(
        adapter: &EditorSceneAdapter,
        id: u64,
        value: Vec<ParticleSubEmitter>,
    ) -> bool {
        match field(adapter, id, "particle-emitter", "particle-sub-emitters") {
            Some(EditorInspectorFieldValue::ParticleSubEmitters(binding)) => {
                binding.set(value);
                true
            }
            _ => false,
        }
    }

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);

    // Group 1: emission core.
    assert!(set_number(&adapter, id, "particle-rate", 42.0));
    assert_eq!(
        emitter(&adapter, entity).settings.emission.emission_rate,
        42.0
    );
    assert!(set_curve(
        &adapter,
        id,
        "particle-rate-curve",
        ParticleCurve::Constant(1.5)
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .emission
            .emission_rate_curve,
        ParticleCurve::Constant(1.5)
    );
    assert!(set_number(&adapter, id, "particle-duration", 2.5));
    assert_eq!(emitter(&adapter, entity).settings.emission.duration, 2.5);
    assert!(set_number(&adapter, id, "particle-simulation-speed", 0.25));
    assert_eq!(
        emitter(&adapter, entity).settings.emission.simulation_speed,
        0.25
    );
    assert!(set_number(&adapter, id, "particle-prewarm-time", 1.25));
    assert_eq!(
        emitter(&adapter, entity).settings.emission.prewarm_time,
        1.25
    );
    assert!(set_number(&adapter, id, "particle-prewarm-step", 0.05));
    assert_eq!(
        emitter(&adapter, entity).settings.emission.prewarm_step,
        0.05
    );
    assert!(set_number(&adapter, id, "particle-max", 128.0));
    assert_eq!(
        emitter(&adapter, entity).settings.emission.max_particles,
        128
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-max-spawned-per-frame",
        48.0
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .emission
            .max_spawned_particles_per_frame,
        48
    );
    assert!(set_number(&adapter, id, "particle-max-rendered", 64.0));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .emission
            .max_rendered_particles,
        64
    );
    assert!(set_number(&adapter, id, "particle-burst-count", 4.8));
    assert_eq!(emitter(&adapter, entity).settings.emission.burst_count, 5);
    assert!(set_number(&adapter, id, "particle-burst-interval", 0.25));
    assert_eq!(
        emitter(&adapter, entity).settings.emission.burst_interval,
        0.25
    );

    // Group 2: distance emission and legacy sub-emitter scalars.
    assert!(set_number(&adapter, id, "particle-distance-rate", 12.0));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .emission
            .distance_emission_rate,
        12.0
    );
    let distance_curve = ParticleCurve::Keyframes(vec![
        ParticleCurveKeyframe::new(0.0, 0.0),
        ParticleCurveKeyframe::new(1.0, 2.0),
    ]);
    assert!(set_curve(
        &adapter,
        id,
        "particle-distance-rate-curve",
        distance_curve.clone()
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .emission
            .distance_emission_rate_curve,
        distance_curve
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-sub-emitter-trigger",
        ParticleSubEmitterTrigger::Collision.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_trigger,
        ParticleSubEmitterTrigger::Collision
    );
    assert!(set_number(&adapter, id, "particle-sub-emitter-burst", 3.8));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_burst_count,
        4
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-sub-emitter-probability",
        0.75
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_probability,
        0.75
    );
    assert!(set_number(&adapter, id, "particle-sub-emitter-depth", 2.2));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_max_depth,
        2
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-sub-emitter-inherit",
        0.45
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_inherit_velocity,
        0.45
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-sub-emitter-lifetime",
        0.6
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_lifetime,
        0.6
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-sub-emitter-start-size",
        0.2
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_start_size,
        0.2
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-sub-emitter-end-size",
        0.05
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .legacy_end_size,
        0.05
    );
    // Group 3: sub-emitter rules preserve list editing and clamping.
    let sub_emitter_field = field(&adapter, id, "particle-emitter", "particle-sub-emitters");
    assert!(matches!(
        sub_emitter_field,
        Some(EditorInspectorFieldValue::ParticleSubEmitters(_))
    ));
    if let Some(EditorInspectorFieldValue::ParticleSubEmitters(binding)) = sub_emitter_field {
        assert!(binding.get().is_empty());
    }
    let authored_rules = vec![
        ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::Death,
            4,
            0.5,
            1,
            0.25,
            0.4,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.1, 0.2, 0.3),
            0.3,
            0.1,
            Float4::new(1.0, 0.5, 0.25, 1.0),
            Float4::new(1.0, 0.2, 0.1, 0.0),
        ),
        ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::Collision,
            2,
            1.0,
            2,
            0.0,
            0.2,
            Float3::new(1.0, 0.0, 0.0),
            Float3::ZERO,
            0.2,
            0.0,
            Float4::new(0.2, 0.4, 1.0, 1.0),
            Float4::new(0.2, 0.4, 1.0, 0.0),
        ),
    ];
    assert!(set_sub_emitters(&adapter, id, authored_rules.clone()));
    let rules = emitter(&adapter, entity).settings.sub_emitters.rules;
    assert_eq!(rules.len(), 2);
    assert_eq!(rules[0].trigger, ParticleSubEmitterTrigger::Death);
    assert_eq!(rules[1].trigger, ParticleSubEmitterTrigger::Collision);

    let mut edited = authored_rules;
    edited[0].burst_count = -3;
    edited[0].probability = 2.0;
    edited[0].max_depth = -1;
    edited[0].inherit_velocity = -0.25;
    edited[0].lifetime = -2.0;
    edited[0].start_size = -1.0;
    edited[0].end_size = -1.0;
    edited.pop();
    assert!(set_sub_emitters(&adapter, id, edited));
    let stored = emitter(&adapter, entity).settings.sub_emitters.rules;
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].burst_count, 0);
    assert_eq!(stored[0].probability, 1.0);
    assert_eq!(stored[0].max_depth, 0);
    assert_eq!(stored[0].inherit_velocity, 0.0);
    assert_eq!(stored[0].lifetime, 0.0001);
    assert_eq!(stored[0].start_size, 0.0);
    assert_eq!(stored[0].end_size, 0.0);
    assert!(set_sub_emitters(&adapter, id, Vec::new()));
    assert!(
        emitter(&adapter, entity)
            .settings
            .sub_emitters
            .rules
            .is_empty()
    );

    assert!(set_number(
        &adapter,
        id,
        "particle-texture-sheet-columns",
        4.0
    ));
    assert_eq!(emitter(&adapter, entity).settings.texture_sheet.columns, 4);

    // Group 4: texture sheet, trails and emission toggle.
    assert!(set_number(&adapter, id, "particle-texture-sheet-rows", 2.0));
    assert_eq!(emitter(&adapter, entity).settings.texture_sheet.rows, 2);
    assert!(set_number(
        &adapter,
        id,
        "particle-texture-sheet-frames",
        7.2
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.texture_sheet.frame_count,
        7
    );
    assert!(set_number(&adapter, id, "particle-texture-sheet-fps", 12.0));
    assert_eq!(
        emitter(&adapter, entity).settings.texture_sheet.frame_rate,
        12.0
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-texture-sheet-playback",
        ParticleTextureSheetPlaybackMode::Loop.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .texture_sheet
            .playback_mode,
        ParticleTextureSheetPlaybackMode::Loop
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-texture-sheet-start-frame",
        3.2
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.texture_sheet.start_frame,
        3
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-texture-sheet-random",
        2.9
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .texture_sheet
            .frame_randomness,
        3
    );
    assert!(set_number(&adapter, id, "particle-trail-length", 0.75));
    assert_eq!(emitter(&adapter, entity).settings.trails.trail_length, 0.75);
    assert!(set_number(&adapter, id, "particle-trail-segments", 6.2));
    assert_eq!(emitter(&adapter, entity).settings.trails.trail_segments, 6);
    assert!(set_number(&adapter, id, "particle-trail-end-size", 0.35));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .trails
            .trail_end_size_scale,
        0.35
    );
    assert!(set_number(&adapter, id, "particle-trail-end-alpha", 0.2));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .trails
            .trail_end_alpha_scale,
        0.2
    );
    assert!(set_bool(&adapter, id, "particle-emitting", false));
    assert!(!emitter(&adapter, entity).settings.emission.is_emitting);
    // Group 5: shape, collision, simulation and force scalars.
    assert!(set_option(
        &adapter,
        id,
        "particle-shape",
        ParticleEmissionShape::Cone.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.shape.emission_shape,
        ParticleEmissionShape::Cone
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-collision-mode",
        ParticleCollisionMode::WorldPlane.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.collision.collision_mode,
        ParticleCollisionMode::WorldPlane
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-simulation-space",
        ParticleSimulationSpace::World.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .gpu_simulation
            .simulation_space,
        ParticleSimulationSpace::World
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-simulation-backend",
        ParticleSimulationBackend::GpuRequired.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .gpu_simulation
            .simulation_backend,
        ParticleSimulationBackend::GpuRequired
    );
    let Some(EditorInspectorFieldValue::ConstrainedNumber {
        binding: workgroup_size,
        min: Some(minimum),
        max: Some(maximum),
        ..
    }) = field(
        &adapter,
        id,
        "particle-emitter",
        "particle-gpu-workgroup-size",
    )
    else {
        panic!("missing GPU workgroup field");
    };
    assert_eq!(minimum, 1.0);
    assert_eq!(
        maximum,
        diffuse_scene::particles::particle_gpu_simulation_plan::ParticleGPUSimulationPlan::MAXIMUM_WORKGROUP_SIZE
            as f32
    );
    workgroup_size.set(128.0);
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .gpu_simulation
            .workgroup_size,
        128
    );
    let Some(EditorInspectorFieldValue::ReadOnly(gpu_status)) =
        field(&adapter, id, "particle-emitter", "particle-gpu-status")
    else {
        panic!("missing GPU status field");
    };
    assert_eq!(gpu_status, "Supported (1x128)");
    assert!(set_number(
        &adapter,
        id,
        "particle-collision-restitution",
        0.7
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .collision
            .collision_restitution,
        0.7
    );
    assert!(set_number(&adapter, id, "particle-noise-strength", 1.5));
    assert_eq!(
        emitter(&adapter, entity).settings.forces.noise_strength,
        1.5
    );
    assert!(set_number(&adapter, id, "particle-noise-scale", 2.5));
    assert_eq!(emitter(&adapter, entity).settings.forces.noise_scale, 2.5);
    assert!(set_number(&adapter, id, "particle-noise-speed", 0.75));
    assert_eq!(emitter(&adapter, entity).settings.forces.noise_speed, 0.75);
    assert!(set_option(
        &adapter,
        id,
        "particle-force-mode",
        ParticleForceMode::Vortex.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.forces.force_mode,
        ParticleForceMode::Vortex
    );

    // Group 6: force field and size curve.
    assert!(set_number(&adapter, id, "particle-force-radius", 12.0));
    assert_eq!(emitter(&adapter, entity).settings.forces.force_radius, 12.0);
    assert!(set_number(&adapter, id, "particle-force-strength", -3.5));
    assert_eq!(
        emitter(&adapter, entity).settings.forces.force_strength,
        -3.5
    );
    assert!(set_number(&adapter, id, "particle-force-falloff", 2.5));
    assert_eq!(emitter(&adapter, entity).settings.forces.force_falloff, 2.5);
    assert!(set_option(
        &adapter,
        id,
        "particle-vector-field-mode",
        ParticleVectorFieldMode::Curl.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.forces.vector_field_mode,
        ParticleVectorFieldMode::Curl
    );
    assert!(set_vector3(
        &adapter,
        id,
        "particle-vector-field-direction",
        (0.0, 0.0, 1.0)
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .forces
            .vector_field_direction,
        Float3::new(0.0, 0.0, 1.0)
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-vector-field-strength",
        6.5
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .forces
            .vector_field_strength,
        6.5
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-vector-field-scale",
        2.25
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.forces.vector_field_scale,
        2.25
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-vector-field-scroll",
        0.5
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .forces
            .vector_field_scroll_speed,
        0.5
    );
    let size_curve = ParticleCurve::Keyframes(vec![
        ParticleCurveKeyframe::new(0.0, 0.0),
        ParticleCurveKeyframe::new(1.0, 1.0),
    ]);
    assert!(set_curve(
        &adapter,
        id,
        "particle-size-curve",
        size_curve.clone()
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.appearance.size_curve,
        size_curve
    );

    // Group 7: appearance and renderer scalars.
    assert!(set_number(&adapter, id, "particle-size-randomness", 0.3));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .appearance
            .size_randomness,
        0.3
    );
    assert!(set_number(&adapter, id, "particle-rotation", 0.4));
    assert_eq!(
        emitter(&adapter, entity).settings.appearance.start_rotation,
        0.4
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-rotation-randomness",
        0.2
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .appearance
            .rotation_randomness,
        0.2
    );
    assert!(set_number(&adapter, id, "particle-angular-velocity", 1.5));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .appearance
            .angular_velocity,
        1.5
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-angular-velocity-randomness",
        0.75
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .appearance
            .angular_velocity_randomness,
        0.75
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-velocity-inheritance",
        0.4
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .velocity
            .velocity_inheritance,
        0.4
    );
    assert!(set_curve(
        &adapter,
        id,
        "particle-color-curve",
        ParticleCurve::EaseOut
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.appearance.color_curve,
        ParticleCurve::EaseOut
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-blend-mode",
        ParticleBlendMode::Additive.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.appearance.blend_mode,
        ParticleBlendMode::Additive
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-render-alignment",
        ParticleRenderAlignment::Velocity.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity).settings.renderer.render_alignment,
        ParticleRenderAlignment::Velocity
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-velocity-stretch-scale",
        0.5
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .velocity_stretch_scale,
        0.5
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-velocity-stretch-max",
        6.0
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .velocity_stretch_max,
        6.0
    );

    // Group 8: render distance, bounds and texture asset.
    assert!(set_number(
        &adapter,
        id,
        "particle-max-render-distance",
        120.0
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .max_render_distance,
        120.0
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-render-distance-fade",
        24.0
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .render_distance_fade_range,
        24.0
    );
    assert!(set_number(&adapter, id, "particle-render-lod-start", 40.0));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .render_lod_start_distance,
        40.0
    );
    assert!(set_number(&adapter, id, "particle-render-lod-end", 120.0));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .render_lod_end_distance,
        120.0
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-render-lod-min-scale",
        0.3
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .render_lod_min_particle_scale,
        0.3
    );
    assert!(set_option(
        &adapter,
        id,
        "particle-render-bounds-mode",
        ParticleRenderBoundsMode::Automatic.inspector_option_id()
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .render_bounds_mode,
        ParticleRenderBoundsMode::Automatic
    );
    assert!(set_number(
        &adapter,
        id,
        "particle-render-bounds-radius",
        48.0
    ));
    assert_eq!(
        emitter(&adapter, entity)
            .settings
            .renderer
            .render_bounds_radius,
        48.0
    );
    let Some(EditorInspectorFieldValue::ReadOnly(estimate)) = field(
        &adapter,
        id,
        "particle-emitter",
        "particle-render-bounds-estimate",
    ) else {
        panic!("missing render bounds estimate field");
    };
    assert!(!estimate.is_empty());

    let Some(EditorInspectorFieldValue::Asset {
        binding: texture_asset,
        accepted_kinds,
        ..
    }) = field(&adapter, id, "particle-emitter", "particle-texture")
    else {
        panic!("missing particle texture asset field");
    };
    assert_eq!(
        accepted_kinds,
        std::collections::BTreeSet::from(["Texture".to_string()])
    );
    texture_asset.set(Some(
        crate::scene::editor_inspector_schema::EditorInspectorAssetRef::with_options(
            "Assets/Textures/smoke.png",
            "smoke",
            Some("/tmp/particle-smoke.png".to_string()),
            "Texture",
            None,
        ),
    ));
    let settings = emitter(&adapter, entity).settings;
    assert_eq!(
        settings.texture_sheet.texture_asset_id.as_deref(),
        Some("Assets/Textures/smoke.png")
    );
    assert_eq!(
        settings.texture_sheet.texture_path.as_deref(),
        Some("/tmp/particle-smoke.png")
    );
    texture_asset.set(None);
    let settings = emitter(&adapter, entity).settings;
    assert!(settings.texture_sheet.texture_asset_id.is_none());
    assert!(settings.texture_sheet.texture_path.is_none());
}

/// Script component exposes catalog selection and binding actions.
#[test]
fn script_catalog_inspector() {
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_script::core::script_component::ScriptComponent;

    use crate::scripting::dynamic::project_script_catalog::ProjectScriptCatalog;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    );
    adapter.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
    let id = make_entity(&adapter);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    assert!(adapter.add_component("script", id));

    let Some(EditorInspectorFieldValue::StringOptions {
        binding: identifier,
        options,
    }) = field(&adapter, id, "scripts", "script-0-identifier")
    else {
        panic!("expected script catalog selector");
    };
    assert_eq!(identifier.get(), "cove.rotator");
    assert!(
        options
            .iter()
            .any(|option| option.value == "cove.character-controller")
    );

    adapter.register_dynamic_script_option("scripts.player-movement", "PlayerMovement", &[]);
    let Some(EditorInspectorFieldValue::StringOptions {
        options: updated_options,
        ..
    }) = field(&adapter, id, "scripts", "script-0-identifier")
    else {
        panic!("expected updated catalog selector");
    };
    assert!(updated_options.iter().any(|option| {
        option.value == "scripts.player-movement" && option.label == "PlayerMovement · Swift"
    }));

    identifier.set("cove.mover".to_string());
    assert_eq!(
        adapter
            .scene()
            .component::<ScriptComponent>(entity)
            .and_then(|component| component
                .bindings
                .first()
                .and_then(|binding| binding.identifier.clone())),
        Some("cove.mover".to_string())
    );

    let Some(EditorInspectorFieldValue::Action { action: add, .. }) =
        field(&adapter, id, "scripts", "script-add")
    else {
        panic!("expected add script action");
    };
    add();
    assert_eq!(
        adapter
            .scene()
            .component::<ScriptComponent>(entity)
            .map(|component| component.bindings.len()),
        Some(2)
    );

    let Some(EditorInspectorFieldValue::Action {
        is_destructive,
        action: remove,
        ..
    }) = field(&adapter, id, "scripts", "script-1-remove")
    else {
        panic!("expected remove script action");
    };
    assert!(is_destructive);
    remove();
    assert_eq!(
        adapter
            .scene()
            .component::<ScriptComponent>(entity)
            .map(|component| component.bindings.len()),
        Some(1)
    );
}
