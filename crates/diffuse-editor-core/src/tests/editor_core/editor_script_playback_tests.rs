//! `Editor/Tests/EditorCoreTests/EditorScriptPlaybackTests.swift`.
//!
//! Gameplay runs only while the editor is in Play, Pause freezes the callbacks,
//! and every Play starts a fresh lifecycle without touching the authored scene
//! or the saved manifest.

use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use diffuse_scene::entity_id::EntityID;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_script::core::script_component::{ScriptBinding, ScriptComponent};
use diffuse_script::core::script_context::ScriptContext;
use diffuse_script::core::script_lifecycle::{Script, ScriptCallback};
use diffuse_script::core::script_runtime::ScriptRuntime;

use crate::application::editor_application::{EditorApplication, EditorApplicationOptions};
use crate::scene::adapter::spawn::EditorEntityTemplate;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::PlaybackState;

/// Swift's `PlaybackCallbacks`.
#[derive(Default)]
struct PlaybackCallbacks {
    values: Mutex<Vec<String>>,
}

impl PlaybackCallbacks {
    fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    fn record(&self, value: &str) {
        self.values
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(value.to_string());
    }

    fn values(&self) -> Vec<String> {
        self.values
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone()
    }
}

/// `authoredSnapshot(_:)` — the export timestamp is not authored state, so it is
/// dropped before comparing the two lifecycle snapshots.
fn authored_snapshot(manifest: &EditorSceneManifest) -> EditorSceneManifest {
    let mut copy = manifest.clone();
    copy.last_modified_at = None;
    copy
}

#[test]
fn gameplay_starts_only_in_play_and_each_play_gets_a_new_lifecycle() {
    let project = std::env::temp_dir().join(format!(
        "cove-script-playback-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    fs::create_dir(&project).expect("project directory");
    let app = EditorApplication::with_options(
        project.to_string_lossy().into_owned(),
        EditorApplicationOptions {
            seed_preview_scene: false,
            ..EditorApplicationOptions::default()
        },
    )
    .expect("launch editor");

    app.bootstrap().expect("start engine");
    let callbacks = PlaybackCallbacks::new();
    let controller = app
        .scene
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("spawn controller");
    register_playback_script(&app.scene.script_runtime, &callbacks);
    assert!(app.scene.with_scene_mut(|scene| {
        scene.set_component(
            ScriptComponent::new(vec![ScriptBinding::with_identifier("test.playback")]),
            EntityID::from_raw_value(controller),
        )
    }));
    app.scene.notify_revision_changed_default();

    let saved_url = app.save_scene_manifest().expect("save scene manifest");
    let saved_data = fs::read(&saved_url).expect("saved bytes");

    app.tick(1.0 / 60.0);
    assert!(callbacks.values().is_empty());
    assert_eq!(app.scene.entity_count(), 1);

    app.store.dispatch(EditorAction::SetViewportRealtime(true));
    app.tick(1.0 / 60.0);
    assert!(callbacks.values().is_empty());

    let authored = app.scene.manifest();
    app.apply_playback_state(PlaybackState::Playing);
    app.tick(1.0 / 60.0);
    assert_eq!(callbacks.values(), ["start", "update"]);
    assert_eq!(app.scene.entity_count(), 2);

    app.apply_playback_state(PlaybackState::Paused);
    app.tick(1.0 / 60.0);
    assert_eq!(callbacks.values(), ["start", "update"]);

    app.apply_playback_state(PlaybackState::Playing);
    app.tick(1.0 / 60.0);
    assert_eq!(callbacks.values(), ["start", "update", "update"]);

    app.apply_playback_state(PlaybackState::Stopped);
    assert_eq!(callbacks.values(), ["start", "update", "update", "destroy"]);
    assert_eq!(
        authored_snapshot(&app.scene.manifest()),
        authored_snapshot(&authored)
    );
    assert!(!app.has_unsaved_scene_changes());

    app.tick(1.0 / 60.0);
    app.apply_playback_state(PlaybackState::Playing);
    app.tick(1.0 / 60.0);
    let values = callbacks.values();
    assert_eq!(values[values.len() - 2..], ["start", "update"]);
    assert_eq!(values.iter().filter(|value| **value == "start").count(), 2);
    assert_eq!(app.scene.entity_count(), 2);

    app.apply_playback_state(PlaybackState::Stopped);
    assert_eq!(
        callbacks
            .values()
            .iter()
            .filter(|value| **value == "destroy")
            .count(),
        2
    );
    assert_eq!(fs::read(&saved_url).expect("saved bytes"), saved_data);

    app.shutdown();
    let _ = fs::remove_dir_all(PathBuf::from(&project));
}

fn register_playback_script(runtime: &ScriptRuntime, callbacks: &Arc<PlaybackCallbacks>) {
    let on_start: ScriptCallback = {
        let callbacks = Arc::clone(callbacks);
        Arc::new(move |context: &mut ScriptContext<'_, '_>| {
            callbacks.record("start");
            context.create_entity(Some("Play Object"), LocalTransform::default());
        })
    };
    let on_tick: ScriptCallback = {
        let callbacks = Arc::clone(callbacks);
        Arc::new(move |_context: &mut ScriptContext<'_, '_>| {
            callbacks.record("update");
        })
    };
    let on_destroy: ScriptCallback = {
        let callbacks = Arc::clone(callbacks);
        Arc::new(move |context: &mut ScriptContext<'_, '_>| {
            let value = if context.local_transform().is_some() {
                "destroy"
            } else {
                "invalid-destroy"
            };
            callbacks.record(value);
        })
    };
    runtime.register(
        Script::new(None, None, None, None)
            .on_start(on_start)
            .on_tick(on_tick)
            .on_destroy(on_destroy),
        Some("test.playback"),
    );
}
