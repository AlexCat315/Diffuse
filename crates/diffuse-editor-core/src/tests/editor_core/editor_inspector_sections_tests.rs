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
