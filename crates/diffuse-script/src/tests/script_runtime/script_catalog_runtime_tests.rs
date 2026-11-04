//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptCatalogRuntimeTests.swift`.
//!
//! `SceneSerializer.serializeFull(_:)` / `deserializeFull(_:into:)` are the
//! [`SceneSerializerScriptSupport`] trait methods, which take and return bytes
//! (`Vec<u8>`) and must be in scope.
//!
//! `ScriptBinding(ScriptHandle(rawValue: 999), identifier: "…")` is
//! `ScriptBinding::from_identifier("…", ScriptBindingID::new(), true, "{}")`
//! followed by writing `script` — the Rust initializer takes the handle
//! positionally instead of defaulting it.
//!
//! `DestructibleFragment(sourceEntity:…)` is `DestructibleFragment::new(…)`,
//! which clamps the two lifetimes to `>= 0` exactly as Swift's initializer does.

use std::sync::{Arc, Mutex};

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::destruction::DestructibleFragment;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_bootstrap::SceneNameComponent;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_scene::serialization::scene_serializer::SceneSerializer;

use crate::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use crate::core::script_context::ScriptContext;
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;
use crate::interop::scene_serializer_script_support::SceneSerializerScriptSupport;
use crate::presets::script_presets::ScriptVar;

/// Swift's `ScriptReloadRecorder`.
#[derive(Default)]
struct ScriptReloadRecorder {
    first_starts: usize,
    first_ticks: usize,
    first_destroys: usize,
    second_starts: usize,
    second_ticks: usize,
}

type SharedRecorder = Arc<Mutex<ScriptReloadRecorder>>;

fn recorder() -> SharedRecorder {
    Arc::new(Mutex::new(ScriptReloadRecorder::default()))
}

fn with_recorder<R>(
    recorder: &SharedRecorder,
    body: impl FnOnce(&mut ScriptReloadRecorder) -> R,
) -> R {
    body(&mut recorder.lock().unwrap_or_else(|error| error.into_inner()))
}

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// `ScriptBinding(handle)`.
fn binding(handle: ScriptHandle) -> ScriptBinding {
    ScriptBinding::with_script(handle)
}

/// `ScriptBinding(handle, parametersJSON:)`.
fn binding_with_parameters(handle: ScriptHandle, json: &str) -> ScriptBinding {
    let mut binding = ScriptBinding::with_script(handle);
    binding.parameters_json = json.to_string();
    binding
}

/// `stable identifiers resolve independently of serialized handles`
#[test]
fn stable_identifier_resolution() {
    let scripts = ScriptRuntime::new();
    scripts.register(
        Script::mover(Float3::new(1.0, 0.0, 0.0)),
        Some("project.move"),
    );
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::default(), entity);
    // The serialized handle is stale (999); resolution goes through the identifier.
    let mut stale = ScriptBinding::with_identifier("project.move");
    stale.script = ScriptHandle::new(999);
    runtime.set_component(ScriptComponent::new(vec![stale]), entity);

    runtime.tick(0.5, 0, Vec::new());

    assert_eq!(
        runtime.local_transform(entity).map(|t| t.translation().x),
        Some(0.5)
    );
}

/// `script factories isolate captured state for every binding instance`
#[test]
fn factories_create_per_binding_state() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_factory(
        Some("project.stateful"),
        "{}",
        crate::core::script_definition::ScriptDefinition::default(),
        || {
            let elapsed_ticks = ScriptVar::new(0.0_f32);
            Script::default().on_tick(Arc::new(move |context: &mut ScriptContext<'_, '_>| {
                let elapsed = elapsed_ticks.with_value(|value| {
                    *value += 1.0;
                    *value
                });
                context.translate(Float3::new(elapsed, 0.0, 0.0));
            }))
        },
    );
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let first = runtime.create_entity();
    let second = runtime.create_entity();
    for entity in [first, second] {
        runtime.set_local_transform(LocalTransform::default(), entity);
        runtime.set_component(ScriptComponent::new(vec![binding(handle)]), entity);
    }

    runtime.tick(0.1, 0, Vec::new());
    runtime.tick(0.1, 0, Vec::new());

    // 1 + 2 = 3 per entity, from independent captured state.
    assert_eq!(
        runtime.local_transform(first).map(|t| t.translation().x),
        Some(3.0)
    );
    assert_eq!(
        runtime.local_transform(second).map(|t| t.translation().x),
        Some(3.0)
    );
}

/// `hot replacement destroys the old instance and starts the replacement`
#[test]
fn named_registration_hot_replacement() {
    let recorder = recorder();
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_factory(
        Some("project.reload"),
        "{}",
        crate::core::script_definition::ScriptDefinition::default(),
        {
            let recorder = recorder.clone();
            move || {
                let starts = recorder.clone();
                let ticks = recorder.clone();
                let destroys = recorder.clone();
                Script::new(
                    Some(Arc::new(move |_| {
                        with_recorder(&starts, |r| r.first_starts += 1)
                    })),
                    None,
                    Some(Arc::new(move |_| {
                        with_recorder(&ticks, |r| r.first_ticks += 1)
                    })),
                    Some(Arc::new(move |_| {
                        with_recorder(&destroys, |r| r.first_destroys += 1)
                    })),
                )
            }
        },
    );
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts.clone()));
    let entity = runtime.create_entity();
    runtime.set_component(ScriptComponent::new(vec![binding(handle)]), entity);
    runtime.tick(0.1, 0, Vec::new());

    let replacement_handle = scripts.register_factory(
        Some("project.reload"),
        "{}",
        crate::core::script_definition::ScriptDefinition::default(),
        {
            let recorder = recorder.clone();
            move || {
                let starts = recorder.clone();
                let ticks = recorder.clone();
                Script::new(
                    Some(Arc::new(move |_| {
                        with_recorder(&starts, |r| r.second_starts += 1)
                    })),
                    None,
                    Some(Arc::new(move |_| {
                        with_recorder(&ticks, |r| r.second_ticks += 1)
                    })),
                    None,
                )
            }
        },
    );
    runtime.tick(0.1, 0, Vec::new());

    assert_eq!(replacement_handle, handle);
    let (first_starts, first_ticks, first_destroys, second_starts, second_ticks) =
        with_recorder(&recorder, |r| {
            (
                r.first_starts,
                r.first_ticks,
                r.first_destroys,
                r.second_starts,
                r.second_ticks,
            )
        });
    assert_eq!(first_starts, 1);
    assert_eq!(first_ticks, 1);
    assert_eq!(first_destroys, 1);
    assert_eq!(second_starts, 1);
    assert_eq!(second_ticks, 1);
}

/// `binding parameters override catalog defaults without discarding other defaults`
#[test]
fn binding_parameters_merge_with_defaults() {
    let observed_speed = ScriptVar::new(0.0_f32);
    let observed_mode = ScriptVar::new(String::new());
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_factory(
        Some("project.parameters"),
        r#"{"speed":2,"mode":"walk"}"#,
        crate::core::script_definition::ScriptDefinition::default(),
        {
            let observed_speed = observed_speed.clone();
            let observed_mode = observed_mode.clone();
            move || {
                let speed = observed_speed.clone();
                let mode = observed_mode.clone();
                Script::default().on_tick(Arc::new(move |context: &mut ScriptContext<'_, '_>| {
                    speed.set(context.float_parameter("speed").unwrap_or(0.0));
                    mode.set(
                        context
                            .string_parameter("mode")
                            .map(str::to_string)
                            .unwrap_or_default(),
                    );
                }))
            }
        },
    );
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_component(
        ScriptComponent::new(vec![binding_with_parameters(handle, r#"{"speed":3}"#)]),
        entity,
    );

    runtime.tick(0.1, 0, Vec::new());

    assert_eq!(observed_speed.get(), 3.0);
    assert_eq!(observed_mode.get(), "walk");
}

/// `full scene serialization preserves stable script identifiers`
#[test]
fn full_scene_serialization_preserves_identifiers() {
    let mut source = scene();
    let entity = source.create_entity();
    let binding_id = ScriptBindingID::new();
    let mut persisted = ScriptBinding::with_identifier("project.persisted");
    persisted.id = binding_id.clone();
    persisted.is_enabled = false;
    persisted.parameters_json = r#"{"speed":4}"#.into();
    source.set_component(ScriptComponent::new(vec![persisted]), entity);

    let data = SceneSerializer::serialize_full(&source).expect("the scene serializes");
    let mut restored = scene();
    SceneSerializer::deserialize_full(&data, &mut restored).expect("the scene restores");
    let restored_entity = restored
        .entities()
        .first()
        .copied()
        .expect("the entity restores");
    let restored_binding = restored
        .component::<ScriptComponent>(restored_entity)
        .and_then(|component| component.bindings.first().cloned())
        .expect("the binding restores");

    assert_eq!(
        restored_binding.identifier.as_deref(),
        Some("project.persisted")
    );
    assert!(!restored_binding.is_enabled);
    assert_eq!(restored_binding.parameters_json, r#"{"speed":4}"#);
    assert_eq!(restored_binding.script.raw_value, 0);
    assert_eq!(restored_binding.id, binding_id);
}

/// `full scene serialization keeps scripts aligned when derived fragments are omitted`
#[test]
fn full_scene_serialization_skips_derived_fragments_without_shifting_bindings() {
    let mut source = scene();
    let destruction_source = source.create_entity();
    let derived_fragment = source.create_entity();
    source.set_component(
        DestructibleFragment::new(destruction_source, 0, 0.0, 1.0, 1.0),
        derived_fragment,
    );
    let scripted_entity = source.create_entity();
    source.set_component(
        SceneNameComponent {
            value: "Scripted".into(),
        },
        scripted_entity,
    );
    source.set_component(
        ScriptComponent::new(vec![ScriptBinding::with_identifier(
            "project.after-fragment",
        )]),
        scripted_entity,
    );

    let data = SceneSerializer::serialize_full(&source).expect("the scene serializes");
    let mut restored = scene();
    SceneSerializer::deserialize_full(&data, &mut restored).expect("the scene restores");

    assert_eq!(restored.entities().len(), 2);
    assert!(restored.entities_with::<DestructibleFragment>().is_empty());
    let restored_scripted = restored
        .entities()
        .into_iter()
        .find(|entity| {
            restored
                .component::<SceneNameComponent>(*entity)
                .map(|name| name.value == "Scripted")
                .unwrap_or(false)
        })
        .expect("the scripted entity restores");
    assert_eq!(
        restored
            .component::<ScriptComponent>(restored_scripted)
            .and_then(|component| component.bindings.first().map(|b| b.identifier.clone())),
        Some(Some("project.after-fragment".to_string()))
    );
    let restored_source = restored
        .entities()
        .into_iter()
        .find(|entity| *entity != restored_scripted)
        .expect("the source entity restores");
    assert!(
        restored
            .component::<ScriptComponent>(restored_source)
            .is_none()
    );
}

/// `full scene deserialization attaches scripts only to newly loaded entities`
#[test]
fn full_scene_deserialization_into_populated_world_uses_returned_entity_map() {
    let mut source = scene();
    let scripted_entity = source.create_entity();
    source.set_component(
        ScriptComponent::new(vec![ScriptBinding::with_identifier("project.loaded")]),
        scripted_entity,
    );
    let data = SceneSerializer::serialize_full(&source).expect("the scene serializes");

    let mut restored = scene();
    let existing = restored.create_entity();
    restored.set_component(
        SceneNameComponent {
            value: "Existing".into(),
        },
        existing,
    );
    SceneSerializer::deserialize_full(&data, &mut restored).expect("the scene restores");

    assert!(restored.component::<ScriptComponent>(existing).is_none());
    let loaded = restored
        .entities()
        .into_iter()
        .find(|entity| *entity != existing)
        .expect("the loaded entity restores");
    assert_eq!(
        restored
            .component::<ScriptComponent>(loaded)
            .and_then(|component| component.bindings.first().map(|b| b.identifier.clone())),
        Some(Some("project.loaded".to_string()))
    );
}
