//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptRuntimeLifecycleTests.swift`.
//!
//! Swift's `ScriptLifecycleRecorder` is a reference type shared with the
//! callbacks; Rust's is an `Arc<Mutex<…>>` for the same effect.
//! `scripts.isGameplayExecutionEnabled = false` is
//! `scripts.set_gameplay_execution_enabled(false)`.
//!
//! `Script(behavior: StatefulScriptBehavior.self)` is
//! `scripts.register_behavior::<StatefulScriptBehavior>(…)`.
//! `ScriptBinding(handle)` is `ScriptBinding::with_script(handle)`, and
//! `disabledFirst.isEnabled = false` writes the public `is_enabled` field.

use std::sync::{Arc, Mutex};

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::collider::{Collider, ColliderShape};
use diffuse_scene::physics::queries::physics_query_types::PhysicsQueryFilter;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_behavior::ScriptBehavior;
use crate::core::script_component::{ScriptBinding, ScriptComponent};
use crate::core::script_context::ScriptContext;
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;

/// Swift's `ScriptLifecycleRecorder`.
#[derive(Default)]
struct ScriptLifecycleRecorder {
    starts: usize,
    ticks: usize,
    destroys: usize,
    ticked_instance_ids: Vec<usize>,
    created_instances: usize,
}

impl ScriptLifecycleRecorder {
    fn make_instance_id(&mut self) -> usize {
        self.created_instances += 1;
        self.created_instances
    }
}

type SharedRecorder = Arc<Mutex<ScriptLifecycleRecorder>>;

fn recorder() -> SharedRecorder {
    Arc::new(Mutex::new(ScriptLifecycleRecorder::default()))
}

fn with_recorder<R>(
    recorder: &SharedRecorder,
    body: impl FnOnce(&mut ScriptLifecycleRecorder) -> R,
) -> R {
    body(&mut recorder.lock().unwrap_or_else(|error| error.into_inner()))
}

/// Swift's `ScriptHitLog`.
#[derive(Clone, Debug, PartialEq)]
struct ScriptHitLog {
    entities: Vec<diffuse_scene::entity_id::EntityID>,
}

/// `StatefulScriptBehavior`: counts its own updates and translates by the count.
#[derive(Default)]
struct StatefulScriptBehavior {
    update_count: f32,
}

impl ScriptBehavior for StatefulScriptBehavior {
    fn on_update(&mut self, context: &mut ScriptContext<'_, '_>) {
        self.update_count += 1.0;
        context.translate(Float3::new(self.update_count, 0.0, 0.0));
    }
}

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn box_collider() -> Collider {
    Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(0.5, 0.5, 0.5),
        center: Float3::ZERO,
    })
}

/// `suspending and ending a session preserve factories and pass live parameters to destruction`
#[test]
fn session_lifecycle() {
    let recorder = recorder();
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_factory(
        Some("session"),
        r#"{"default":7}"#,
        crate::core::script_definition::ScriptDefinition::default(),
        {
            let recorder = recorder.clone();
            move || {
                let starts = recorder.clone();
                let ticks = recorder.clone();
                let destroys = recorder.clone();
                Script::new(
                    Some(Arc::new(move |_| with_recorder(&starts, |r| r.starts += 1))),
                    None,
                    Some(Arc::new(move |_| with_recorder(&ticks, |r| r.ticks += 1))),
                    Some(Arc::new(move |context: &mut ScriptContext<'_, '_>| {
                        // The live parameters must still be readable at destruction.
                        if context.local_transform().is_some()
                            && context.double_parameter("value") == Some(42.0)
                            && context.double_parameter("default") == Some(7.0)
                        {
                            with_recorder(&destroys, |r| r.destroys += 1);
                        }
                    })),
                )
            }
        },
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts.clone()));
    let entity = scene.create_entity();
    scene.set_local_transform(LocalTransform::IDENTITY, entity);
    let mut binding = ScriptBinding::with_script(handle);
    binding.parameters_json = r#"{"value":42}"#.into();
    scene.set_component(ScriptComponent::new(vec![binding]), entity);

    scripts.set_gameplay_execution_enabled(false);
    scene.tick(0.1, 0, Vec::new());
    let (starts, ticks) = with_recorder(&recorder, |r| (r.starts, r.ticks));
    assert_eq!(starts, 0);
    assert_eq!(ticks, 0);

    scripts.set_gameplay_execution_enabled(true);
    scene.tick(0.1, 0, Vec::new());
    scripts.set_gameplay_execution_enabled(false);
    scene.tick(0.1, 0, Vec::new());
    let (starts, ticks, destroys) = with_recorder(&recorder, |r| (r.starts, r.ticks, r.destroys));
    assert_eq!(starts, 1);
    assert_eq!(ticks, 1);
    assert_eq!(destroys, 0);

    // Two stops destroy the single live instance exactly once.
    scripts.stop(&mut scene);
    scripts.stop(&mut scene);
    assert_eq!(with_recorder(&recorder, |r| r.destroys), 1);
    // The factory registration survives the session end.
    assert_eq!(scripts.handle("session"), Some(handle));

    scripts.set_gameplay_execution_enabled(true);
    scene.tick(0.1, 0, Vec::new());
    let (starts, ticks) = with_recorder(&recorder, |r| (r.starts, r.ticks));
    assert_eq!(starts, 2);
    assert_eq!(ticks, 2);
}

/// `registered scripts run start once and drive same-frame world updates`
#[test]
fn registered_scripts_run_lifecycle_through_scene_runtime() {
    let recorder = recorder();
    let scripts = ScriptRuntime::new();
    let script = scripts.register_factory(
        Some("mover"),
        "{}",
        crate::core::script_definition::ScriptDefinition::default(),
        {
            let recorder = recorder.clone();
            move || {
                let starts = recorder.clone();
                let ticks = recorder.clone();
                let destroys = recorder.clone();
                Script::new(
                    Some(Arc::new(move |_| with_recorder(&starts, |r| r.starts += 1))),
                    None,
                    Some(Arc::new(move |context: &mut ScriptContext<'_, '_>| {
                        with_recorder(&ticks, |r| r.ticks += 1);
                        context.translate(Float3::new(context.delta_time as f32, 0.0, 0.0));
                    })),
                    Some(Arc::new(move |_| {
                        with_recorder(&destroys, |r| r.destroys += 1)
                    })),
                )
            }
        },
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));

    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::from_translation(Float3::ZERO), entity);
    runtime.set_component(box_collider(), entity);
    runtime.set_component(ScriptComponent::from_scripts([script]), entity);

    runtime.tick(0.25, 0, Vec::new());
    runtime.tick(0.5, 0, Vec::new());

    let (starts, ticks, destroys) = with_recorder(&recorder, |r| (r.starts, r.ticks, r.destroys));
    assert_eq!(starts, 1);
    assert_eq!(ticks, 2);
    assert_eq!(destroys, 0);
    assert_eq!(
        runtime.local_transform(entity).map(|t| t.translation()),
        Some(Float3::new(0.75, 0.0, 0.0))
    );
    let bounds_center = runtime
        .spatial_index()
        .entries
        .first()
        .map(|entry| entry.bounds.center());
    assert_eq!(bounds_center, Some(Float3::new(0.75, 0.0, 0.0)));
}

/// `removing a script binding triggers onDestroy on the next frame`
#[test]
fn removing_script_binding_triggers_destroy() {
    let recorder = recorder();
    let scripts = ScriptRuntime::new();
    let script = scripts.register_factory(
        Some("marker"),
        "{}",
        crate::core::script_definition::ScriptDefinition::default(),
        {
            let recorder = recorder.clone();
            move || {
                let starts = recorder.clone();
                let destroys = recorder.clone();
                Script::new(
                    Some(Arc::new(move |_| with_recorder(&starts, |r| r.starts += 1))),
                    None,
                    None,
                    Some(Arc::new(move |_| {
                        with_recorder(&destroys, |r| r.destroys += 1)
                    })),
                )
            }
        },
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));

    let entity = runtime.create_entity();
    runtime.set_component(ScriptComponent::from_scripts([script]), entity);

    runtime.tick(0.1, 0, Vec::new());
    runtime.remove_component::<ScriptComponent>(entity);
    runtime.tick(0.1, 0, Vec::new());

    let (starts, destroys) = with_recorder(&recorder, |r| (r.starts, r.destroys));
    assert_eq!(starts, 1);
    assert_eq!(destroys, 1);
}

/// `script context exposes direct physics queries`
#[test]
fn script_context_exposes_physics_queries() {
    let scripts = ScriptRuntime::new();
    let query_script = scripts.register(
        Script::default().on_tick(Arc::new(|context: &mut ScriptContext<'_, '_>| {
            let hit = context.raycast(
                Float3::new(-5.0, 0.0, 0.0),
                Float3::new(1.0, 0.0, 0.0),
                20.0,
                PhysicsQueryFilter::with_options(None, Default::default(), false, Some(1), 0b0010),
            );
            context.set_resource(ScriptHitLog {
                entities: hit.map(|hit| vec![hit.entity]).unwrap_or_default(),
            });
        })),
        None,
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));

    let target = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        target,
    );
    let mut collider = box_collider();
    collider.layer_id = 1;
    collider.layer_mask = 0b0010;
    runtime.set_component(collider, target);

    let entity = runtime.create_entity();
    runtime.set_component(ScriptComponent::from_scripts([query_script]), entity);

    runtime.tick(0.1, 0, Vec::new());

    assert_eq!(
        runtime.resource::<ScriptHitLog>().map(|log| log.entities),
        Some(vec![target])
    );
}

/// `typed script behaviors keep independent state per binding`
#[test]
fn typed_behaviors_keep_state_per_binding() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_behavior::<StatefulScriptBehavior>(Some("typed-counter"), "{}");

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let first_entity = runtime.create_entity();
    let second_entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::from_translation(Float3::ZERO), first_entity);
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::ZERO),
        second_entity,
    );
    runtime.set_component(ScriptComponent::from_scripts([handle]), first_entity);
    runtime.set_component(ScriptComponent::from_scripts([handle]), second_entity);

    runtime.tick(0.1, 0, Vec::new());
    runtime.tick(0.1, 0, Vec::new());

    // Two updates each, with the per-binding state independent: 1 + 2 = 3.
    assert_eq!(
        runtime
            .local_transform(first_entity)
            .map(|t| t.translation()),
        Some(Float3::new(3.0, 0.0, 0.0))
    );
    assert_eq!(
        runtime
            .local_transform(second_entity)
            .map(|t| t.translation()),
        Some(Float3::new(3.0, 0.0, 0.0))
    );
}

/// `duplicate script bindings keep their own state when an earlier binding is disabled`
#[test]
fn duplicate_bindings_keep_stable_instances() {
    let recorder = recorder();
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_factory(
        Some("duplicate"),
        "{}",
        crate::core::script_definition::ScriptDefinition::default(),
        {
            let recorder = recorder.clone();
            move || {
                let instance_id = with_recorder(&recorder, |r| r.make_instance_id());
                let ticks = recorder.clone();
                Script::default().on_tick(Arc::new(move |_| {
                    with_recorder(&ticks, |r| r.ticked_instance_ids.push(instance_id));
                }))
            }
        },
    );

    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    let first = ScriptBinding::with_script(handle);
    let second = ScriptBinding::with_script(handle);
    runtime.set_component(
        ScriptComponent::new(vec![first.clone(), second.clone()]),
        entity,
    );

    runtime.tick(0.1, 0, Vec::new());
    assert_eq!(
        with_recorder(&recorder, |r| r.ticked_instance_ids.clone()),
        vec![1, 2]
    );

    with_recorder(&recorder, |r| r.ticked_instance_ids.clear());
    let mut disabled_first = first;
    disabled_first.is_enabled = false;
    runtime.set_component(ScriptComponent::new(vec![disabled_first, second]), entity);
    runtime.tick(0.1, 0, Vec::new());

    assert_eq!(
        with_recorder(&recorder, |r| r.ticked_instance_ids.clone()),
        vec![2]
    );
    assert_eq!(with_recorder(&recorder, |r| r.created_instances), 2);
}
