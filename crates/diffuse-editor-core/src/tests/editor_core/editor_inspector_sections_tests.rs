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
