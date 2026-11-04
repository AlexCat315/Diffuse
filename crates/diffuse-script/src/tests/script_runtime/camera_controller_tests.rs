//! Ported from `Engine/Tests/ScriptRuntimeTests/CameraControllerTests.swift`.
//!
//! Swift's `SceneRuntime()` takes its component registry in Rust
//! (`SceneRuntime::new(ComponentRegistry::built_in())`), and its `tick(deltaTime:)`
//! gains the frame index and explicit event vector. `setScriptDriver(scripts)`
//! becomes `set_script_driver(Box::new(scripts))` and `ScriptComponent(handle)`
//! becomes `ScriptComponent::from_scripts([handle])`.
//!
//! Swift's `.firstPersonCamera(moveSpeed:lookSensitivity:)` and
//! `.orbitCamera(target:distance:orbitSpeed:zoomSpeed:minDistance:maxDistance:)`
//! are `Script::first_person_camera(move_speed, look_sensitivity)` and
//! `Script::orbit_camera(target, distance, orbit_speed, zoom_speed, min_distance,
//! max_distance)`; the parameters Swift omits keep their Swift defaults.
//! `try #require` becomes `expect`, and `CameraComponent(target:)` becomes a
//! struct update over `CameraComponent::default()`.

use diffuse_kernel::input_event::{
    InputEvent, MouseButton, MouseButtonEvent, MouseMotionEvent, MouseWheelEvent,
};
use diffuse_math::simd::simd_compat::{Float3, simd_length};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::input_action::InputActionMap;
use diffuse_scene::rendering::render_extraction::CameraComponent;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_component::ScriptComponent;
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;
use crate::input::default_input_actions::DefaultInputActions;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// `first-person look updates the render camera target`
#[test]
fn first_person_updates_camera_component() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::first_person_camera(5.0, 0.01),
        Some("camera.first-person"),
    );
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    runtime.set_resource(InputActionMap::cove_default());
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::default(), entity);
    // Swift's `CameraComponent(target: SIMD3<Float>(0, 0, -1))`.
    runtime.set_component(
        CameraComponent {
            target: Float3::new(0.0, 0.0, -1.0),
            ..Default::default()
        },
        entity,
    );
    runtime.set_component(ScriptComponent::from_scripts([handle]), entity);

    runtime.tick(
        0.1,
        0,
        vec![
            InputEvent::MouseButtonDown(MouseButtonEvent {
                button: MouseButton::Right,
                clicks: 1,
                ..Default::default()
            }),
            InputEvent::MouseMotion(MouseMotionEvent {
                delta_x: 50.0,
                ..Default::default()
            }),
        ],
    );

    let camera = runtime
        .component::<CameraComponent>(entity)
        .expect("the camera component must survive the tick");
    assert!(camera.target.x.abs() > 0.1);
    assert!((simd_length(camera.target) - 1.0).abs() < 0.001);
}

/// `orbit camera authors the camera target and responds to wheel zoom`
#[test]
fn orbit_updates_camera_component_and_zoom() {
    let target = Float3::new(1.0, 2.0, 3.0);
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::orbit_camera(target, 10.0, 0.005, 2.0, 1.0, 100.0),
        Some("camera.orbit"),
    );
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    runtime.set_resource(InputActionMap::cove_default());
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::default(), entity);
    runtime.set_component(CameraComponent::default(), entity);
    runtime.set_component(ScriptComponent::from_scripts([handle]), entity);

    runtime.tick(0.1, 0, Vec::new());
    let initial_distance = simd_length(
        runtime
            .local_transform(entity)
            .expect("the orbit camera must place the entity")
            .translation()
            - target,
    );
    runtime.tick(
        0.1,
        1,
        vec![InputEvent::MouseWheel(MouseWheelEvent {
            y: 1.0,
            ..Default::default()
        })],
    );

    let camera = runtime
        .component::<CameraComponent>(entity)
        .expect("the camera component must survive the tick");
    let zoomed_distance = simd_length(
        runtime
            .local_transform(entity)
            .expect("the orbit camera must keep the entity placed")
            .translation()
            - target,
    );
    assert_eq!(camera.target, target);
    assert!((initial_distance - 10.0).abs() < 0.001);
    assert!((zoomed_distance - 8.0).abs() < 0.001);
}
