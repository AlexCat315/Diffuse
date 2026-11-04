//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptCBridgeContextTests.swift`.
//!
//! Swift reads the current callback context from a thread-dictionary slot
//! (`_coveCurrentScriptContext`) that `ScriptRuntime.invoke` sets before each
//! callback and restores afterwards. Rust keeps the same information in the
//! bridge's per-thread `INVOCATIONS` stack, so `current_script_context()`
//! replaces the Swift property and the identity assertions compare the context
//! address instead of a class reference.
//!
//! Swift's `Thread { }.start()` + `DispatchGroup` becomes `std::thread::spawn`
//! plus a condition-variable rendezvous, which keeps the five-second
//! "the other scene did not reach its callback" diagnosis.

use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant};

use crate::core::script_component::ScriptComponent;
use crate::core::script_context::ScriptContext;
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;
use crate::dynamic_script::script_c_bridge_context::{current_delta_time, current_script_context};
use crate::presets::script_presets::ScriptVar;

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::scene_runtime::SceneRuntime;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// `_coveCurrentScriptContext === context` — the callback sees its own context.
fn current_is(context: &mut ScriptContext<'_, '_>) -> bool {
    current_script_context() == Some((context as *mut ScriptContext<'_, '_>).cast())
}

/// One rendezvous shared by the two scene threads.
#[derive(Default)]
struct Rendezvous {
    arrived: Mutex<usize>,
    ready: Condvar,
}

impl Rendezvous {
    /// `ready.leave()` then `ready.wait(timeout: .now() + 5)`.
    fn arrive_and_wait(&self) -> bool {
        let arrived = self.arrived.lock().unwrap();
        let arrived = {
            let mut arrived = arrived;
            *arrived += 1;
            self.ready.notify_all();
            arrived
        };
        // A serial executor may run both closures on one worker; the dedicated
        // threads below guarantee both reach this point, exactly as Swift notes.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut arrived = arrived;
        while *arrived < 2 {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (guard, timeout) = self.ready.wait_timeout(arrived, remaining).unwrap();
            arrived = guard;
            if timeout.timed_out() && *arrived < 2 {
                return false;
            }
        }
        true
    }
}

/// `independent scenes keep their bridge contexts on their own threads`
#[test]
fn concurrent_scenes() {
    let rendezvous = Arc::new(Rendezvous::default());
    let (finished_tx, finished_rx) = mpsc::channel::<()>();
    let failures: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

    for index in 0..2 {
        let rendezvous = rendezvous.clone();
        let finished_tx = finished_tx.clone();
        let callback_failures = failures.clone();
        let thread_failures = failures.clone();
        std::thread::spawn(move || {
            let delta_time = if index == 0 { 0.125_f64 } else { 0.75 };
            let scripts = ScriptRuntime::new();
            let handle = scripts.register(
                Script::default().on_update(Arc::new(move |context| {
                    if !rendezvous.arrive_and_wait() {
                        callback_failures
                            .lock()
                            .unwrap()
                            .push("The other scene did not reach its callback".into());
                        return;
                    }
                    if current_delta_time() != context.delta_time as f32 {
                        callback_failures
                            .lock()
                            .unwrap()
                            .push(format!("delta time {delta_time} not visible to the bridge"));
                    }
                    if !current_is(context) {
                        callback_failures
                            .lock()
                            .unwrap()
                            .push("the bridge context is not this callback's context".into());
                    }
                })),
                None,
            );
            let mut scene = scene();
            scene.set_script_driver(Box::new(scripts.clone()));
            let entity = scene.create_entity();
            scene.set_component(ScriptComponent::from_scripts([handle]), entity);
            scene.tick(delta_time, 0, Vec::new());
            if current_script_context().is_some() {
                thread_failures
                    .lock()
                    .unwrap()
                    .push("the bridge context outlived the tick".into());
            }
            let _ = finished_tx.send(());
        });
    }
    drop(finished_tx);

    // `finished.wait(timeout: .now() + 10) == .success`: both workers must finish.
    for _ in 0..2 {
        if let Err(error) = finished_rx.recv_timeout(Duration::from_secs(10)) {
            panic!("a scene did not finish: {error}");
        }
    }
    let failures = failures.lock().unwrap();
    assert!(failures.is_empty(), "{failures:?}");
}

/// `nested scene callbacks restore the outer bridge context`
#[test]
fn nested_callbacks() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_update(Arc::new(|outer| {
            let outer_pointer = (outer as *mut ScriptContext<'_, '_>).cast();
            let inner_scripts = ScriptRuntime::new();
            let inner_handle = inner_scripts.register(
                Script::default().on_update(Arc::new(|_| {
                    assert_eq!(current_delta_time(), 0.5);
                })),
                None,
            );
            let mut inner = scene();
            inner.set_script_driver(Box::new(inner_scripts));
            let inner_entity = inner.create_entity();
            inner.set_component(ScriptComponent::from_scripts([inner_handle]), inner_entity);
            inner.tick(0.5, 0, Vec::new());
            // The inner tick must not disturb the outer context.
            assert_eq!(current_script_context(), Some(outer_pointer));
            assert_eq!(current_delta_time(), 0.25);
        })),
        None,
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let entity = scene.create_entity();
    scene.set_component(ScriptComponent::from_scripts([handle]), entity);
    scene.tick(0.25, 0, Vec::new());
    assert_eq!(current_script_context(), None);
}

/// `removed bindings receive a C bridge context in onDestroy`
#[test]
fn destroy_callback() {
    let scripts = ScriptRuntime::new();
    let destroyed = ScriptVar::new(false);
    let observed = ScriptVar::new(false);
    let handle = scripts.register(
        Script::default().on_destroy(Arc::new({
            let destroyed = destroyed.clone();
            let observed = observed.clone();
            move |context| {
                destroyed.set(true);
                observed.set(current_is(context));
                assert_eq!(current_delta_time(), 0.25);
            }
        })),
        None,
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let entity = scene.create_entity();
    scene.set_component(ScriptComponent::from_scripts([handle]), entity);
    scene.tick(0.1, 0, Vec::new());
    scene.remove_component::<ScriptComponent>(entity);
    scene.tick(0.25, 0, Vec::new());
    assert!(destroyed.get());
    assert!(observed.get());
    assert_eq!(current_script_context(), None);
}
