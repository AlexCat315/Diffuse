//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptParameterTests.swift`.
//!
//! Swift's `ScriptBinding(script, parametersJSON:)` keeps the memberwise
//! defaults for `id`/`identifier`/`isEnabled`; `ScriptBinding::with_script` is
//! the Rust equivalent, and the JSON is assigned afterwards because
//! `parameters_json` is a plain public field.
//!
//! Swift's `ctx.parameters["speed"] as? Double` bridges a JSON number through
//! NSNumber; `ScriptParameters` is a `BTreeMap<String, JsonValue>`, so the same
//! read is `values.get("speed").and_then(JsonValue::nsnumber_double_value)`.
//! Swift re-reads `ctx.parameters` to observe its cache, but Rust's
//! `ScriptContext::parameters` returns the cached map by reference, so the test
//! calls it twice and asserts the callback ran exactly once.

use std::sync::Arc;

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_component::{ScriptBinding, ScriptComponent};
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;
use crate::presets::script_presets::ScriptVar;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// `ScriptBinding(script, parametersJSON: json)` with everything else defaulted.
fn binding(handle: crate::core::script_component::ScriptHandle, json: &str) -> ScriptBinding {
    let mut binding = ScriptBinding::with_script(handle);
    binding.parameters_json = json.to_string();
    binding
}

/// `parametersJSON is passed to onStart handler`
#[test]
fn parameters_passed_to_on_start() {
    let capture = ScriptVar::new(String::new());
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_start(Arc::new({
            let capture = capture.clone();
            move |context| capture.set(context.parameters_json.clone())
        })),
        None,
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_component(
        ScriptComponent::new(vec![binding(handle, r#"{"speed": 2.5}"#)]),
        entity,
    );
    runtime.tick(0.1, 0, Vec::new());
    assert_eq!(capture.get(), r#"{"speed": 2.5}"#);
}

/// `parametersJSON is passed to onTick handler`
#[test]
fn parameters_passed_to_on_tick() {
    let capture = ScriptVar::new(String::new());
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_tick(Arc::new({
            let capture = capture.clone();
            move |context| capture.set(context.parameters_json.clone())
        })),
        None,
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_component(
        ScriptComponent::new(vec![binding(handle, r#"{"speed": 2.5}"#)]),
        entity,
    );
    runtime.tick(0.1, 0, Vec::new());
    assert_eq!(capture.get(), r#"{"speed": 2.5}"#);
}

/// `parameters decodes JSON into dictionary on access`
#[test]
// Swift's literal is `3.14`; it is a decoded-value probe, not an angle.
#[allow(clippy::approx_constant)]
fn parameters_decodes_json() {
    let speed = ScriptVar::new(0.0_f64);
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_tick(Arc::new({
            let speed = speed.clone();
            move |context| {
                speed.set(
                    context
                        .parameters()
                        .get("speed")
                        .and_then(|value| value.nsnumber_double_value())
                        .unwrap_or(0.0),
                );
            }
        })),
        None,
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_component(
        ScriptComponent::new(vec![binding(handle, r#"{"speed": 3.14}"#)]),
        entity,
    );
    runtime.tick(0.1, 0, Vec::new());
    assert_eq!(speed.get(), 3.14);
}

/// `parameters caches decoded dictionary`
#[test]
fn parameters_caches_decoded_value() {
    let count = ScriptVar::new(0_i64);
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_tick(Arc::new({
            let count = count.clone();
            move |context| {
                // Two reads: the second must come from the cached map.
                let _ = context.parameters();
                let _ = context.parameters();
                count.with_value(|value| *value += 1);
            }
        })),
        None,
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_component(
        ScriptComponent::new(vec![binding(handle, r#"{"x": 1}"#)]),
        entity,
    );
    runtime.tick(0.1, 0, Vec::new());
    assert_eq!(count.get(), 1);
}

/// `parameters returns empty dict for default JSON`
#[test]
fn parameters_empty_for_default_json() {
    let count = ScriptVar::new(0_i64);
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_start(Arc::new({
            let count = count.clone();
            move |context| {
                if context.parameters().is_empty() {
                    count.with_value(|value| *value += 1);
                }
            }
        })),
        None,
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_component(ScriptComponent::from_scripts([handle]), entity);
    runtime.tick(0.1, 0, Vec::new());
    assert_eq!(count.get(), 1);
}
