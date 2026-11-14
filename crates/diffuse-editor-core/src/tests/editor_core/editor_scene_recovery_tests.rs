//! Persistence cases from `EditorSceneRecoveryTests.swift`.

use std::fs;
use std::path::PathBuf;
use std::rc::Rc;

use diffuse_assets::swift_json::to_sorted_pretty;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::runtime_world::LocalTransform;

use crate::application::editor_application::{EditorApplication, EditorApplicationOptions};
use crate::application::persistence::scene_persistence::EditorScenePersistence;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{
    EditorConsoleSeverity, EditorPendingDocumentAction, PlaybackState,
};
use crate::state::editor_store::EditorStore;

struct TempProject(PathBuf);

impl TempProject {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "diffuse-recovery-{}",
            diffuse_kernel::codable::new_uuid()
        ));
        fs::create_dir(&root).expect("project directory");
        Self(root)
    }

    fn session(&self) -> (EditorScenePersistence, EditorSceneAdapter, Rc<EditorStore>) {
        let scene = EditorSceneAdapter::with_defaults(true);
        let store = Rc::new(EditorStore::new());
        let weak = Rc::downgrade(&store);
        scene
            .on_revision_changed
            .replace(Some(Rc::new(move |revision| {
                if let Some(store) = weak.upgrade() {
                    store.dispatch(EditorAction::SetSceneRevision(revision));
                }
            })));
        store.dispatch(EditorAction::SetSceneRevision(scene.revision()));
        store.dispatch(EditorAction::MarkSceneSaved(scene.revision()));
        store.dispatch(EditorAction::SetSelectedEntity(
            scene.default_selection_id(),
        ));
        (
            EditorScenePersistence::new(self.0.clone(), scene.clone(), store.clone()),
            scene,
            store,
        )
    }

    fn app(&self) -> Rc<EditorApplication> {
        EditorApplication::with_options(
            self.0.to_string_lossy().into_owned(),
            EditorApplicationOptions {
                seed_preview_scene: true,
                ..Default::default()
            },
        )
        .expect("editor session")
    }
}

impl Drop for TempProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn explicit_scene_open_restores_selection_and_keeps_the_canonical_save_path() {
    let project = TempProject::new();
    let (_, source, _) = project.session();
    let id = source.default_selection_id().expect("source selection");
    let position = Float3::new(7.0, 8.0, 9.0);
    source.set_entity_local_translation(id, position);
    let manifest = source.manifest_for_selection(Some(id));
    let external = project.0.join("explicit.covescene");
    fs::write(&external, to_sorted_pretty(&manifest).expect("scene JSON")).expect("explicit scene");
    let app = project.app();
    let initial_document = app.store.state().document.identity;
    app.scene
        .set_entity_local_translation(id, Float3::new(9.0, 6.0, 3.0));
    app.request_open_scene_manifest_at(&external);
    let request = app.store.pending_close_request().expect("unsaved prompt");
    assert_eq!(request.action, EditorPendingDocumentAction::OpenScene);
    assert_eq!(request.document_path.as_deref(), external.to_str());
    assert_eq!(app.store.state().document.identity, initial_document);
    app.store.dispatch(EditorAction::DismissCloseRequest);
    assert_eq!(app.open_scene_manifest_at(&external), Some(manifest));
    assert_ne!(app.store.state().document.identity, initial_document);
    assert_eq!(
        app.scene
            .entity_local_translation(app.store.selected_entity_id().expect("selection")),
        Some(position)
    );
    assert!(!app.has_unsaved_scene_changes());
    let canonical_save = app.scene_persistence().scene_manifest_path();
    assert_eq!(app.save_scene_manifest(), Some(canonical_save.clone()));
    assert!(canonical_save.is_file());
    app.shutdown();
}

#[test]
fn corrupt_recovery_is_quarantined_with_its_original_bytes() {
    let project = TempProject::new();
    let (target, _, store) = project.session();
    let path = target.autosave_path();
    let parent = path.parent().expect("autosave directory");
    fs::create_dir_all(parent).expect("autosave directory");
    fs::write(&path, b"not a game save").expect("corrupt autosave");
    assert!(
        target
            .restore_project_scene_at_launch(|manifest| target.load_scene(manifest))
            .is_none()
    );
    assert!(!path.exists());
    let recovered = fs::read_dir(parent)
        .expect("quarantine location")
        .flatten()
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("slot-255.corrupt-")
        })
        .expect("quarantined autosave");
    let name = recovered.file_name().to_string_lossy().into_owned();
    assert_eq!(
        fs::read(recovered.path()).expect("quarantined payload"),
        b"not a game save"
    );
    assert!(store.console_entries().iter().any(|entry| {
        entry.message == "Failed to restore autosaved scene"
            && entry.severity == EditorConsoleSeverity::Warning
            && entry
                .detail
                .as_ref()
                .is_some_and(|detail| detail.contains(&name))
    }));
}

#[test]
fn invalid_playback_transitions_preserve_stopped_state() {
    let project = TempProject::new();
    let (target, _, store) = project.session();
    assert!(!target.apply_playback_state(PlaybackState::Paused));
    assert_eq!(store.playback_state(), PlaybackState::Stopped);
    assert!(!target.apply_playback_state(PlaybackState::Stopped));
    assert_eq!(store.playback_state(), PlaybackState::Stopped);
}

#[test]
fn interrupted_play_becomes_an_autosaved_recovery_on_launch() {
    let project = TempProject::new();
    let (source, scene, _) = project.session();
    let position = Float3::new(12.0, 8.0, -4.0);
    scene.set_entity_local_translation(scene.default_selection_id().expect("entity"), position);
    assert!(source.apply_playback_state(PlaybackState::Playing));
    assert!(source.physics_play_snapshot_path().is_file());
    let (target, scene, store) = project.session();
    let recovered = target
        .restore_project_scene_at_launch(|manifest| target.load_scene(manifest))
        .expect("recovered play");
    assert!(recovered.selected_entity_id.is_some());
    assert_eq!(
        scene.entity_local_translation(store.selected_entity_id().expect("selection")),
        Some(position)
    );
    assert!(store.scene_recovery_pending());
    assert!(target.autosave_path().is_file());
    assert!(!target.physics_play_snapshot_path().exists());
}

#[test]
fn shutdown_autosaves_a_dirty_scene_and_explicit_save_clears_recovery() {
    let project = TempProject::new();
    let source = project.app();
    let id = source.scene.default_selection_id().expect("entity");
    let edited =
        source.scene.entity_local_translation(id).expect("original") + Float3::new(4.0, 5.0, 6.0);
    source.scene.set_entity_local_translation(id, edited);
    assert!(source.has_unsaved_scene_changes());
    let autosave = source.scene_persistence().autosave_path();
    source.shutdown();
    assert!(autosave.is_file());
    drop(source);
    let target = project.app();
    assert!(target.restore_project_scene_at_launch().is_some());
    assert_eq!(
        target
            .scene
            .entity_local_translation(target.store.selected_entity_id().expect("selection")),
        Some(edited)
    );
    assert!(target.has_unsaved_scene_changes() && target.store.scene_recovery_pending());
    assert!(target.save_scene_manifest().is_some());
    assert!(!target.has_unsaved_scene_changes());
    assert!(!autosave.exists());
    target.shutdown();
}

#[test]
fn clean_shutdown_removes_the_owned_play_crash_marker() {
    let project = TempProject::new();
    let app = project.app();
    app.apply_playback_state(PlaybackState::Playing);
    let marker = app.scene_persistence().physics_play_snapshot_path();
    assert!(marker.is_file());
    app.shutdown();
    app.shutdown();
    assert!(!app.is_active());
    assert!(!marker.exists());
}

#[test]
fn corrupt_context_memory_is_quarantined_on_construction() {
    let project = TempProject::new();
    let cove = project.0.join(".cove");
    fs::create_dir(&cove).expect("metadata directory");
    let storage = cove.join("context_memory.json");
    fs::write(&storage, b"invalid context memory").expect("write corruption");
    let app = project.app();
    assert!(app.context_memory_store.is_some());
    let quarantined = fs::read_dir(&cove)
        .expect("metadata entries")
        .flatten()
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("context_memory.corrupt-")
        })
        .expect("quarantined context memory");
    assert_eq!(
        fs::read(quarantined.path()).unwrap(),
        b"invalid context memory"
    );
    assert!(app.store.console_entries().iter().any(|entry| {
        entry.message == "Recovered AI context memory storage"
            && entry.severity == EditorConsoleSeverity::Warning
    }));
    app.shutdown();
    assert_eq!(fs::read_to_string(storage).unwrap().trim(), "[]");
}

#[test]
fn scene_save_during_play_uses_the_authored_snapshot() {
    let project = TempProject::new();
    let (persistence, scene, store) = project.session();
    let id = scene.default_selection_id().expect("entity");
    let original = scene.entity_local_translation(id).expect("original");
    let authored = original + Float3::new(2.0, 3.0, 4.0);
    let runtime = original + Float3::new(20.0, 30.0, 40.0);
    scene.set_entity_local_translation(id, authored);
    assert!(persistence.apply_playback_state(PlaybackState::Playing));
    let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
    matrix.set_column(3, Float4::new(runtime.x, runtime.y, runtime.z, 1.0));
    scene.with_scene_mut(|scene| {
        scene.set_local_transform(LocalTransform::new(matrix), EntityID::from_raw_value(id))
    });
    let saved = persistence.save_scene_manifest(None).expect("saved scene");
    assert_eq!(store.playback_state(), PlaybackState::Playing);
    assert_eq!(scene.entity_local_translation(id), Some(runtime));
    let manifest: EditorSceneManifest =
        serde_json::from_slice(&fs::read(saved).expect("saved scene")).expect("scene manifest");
    let restored = EditorSceneAdapter::with_defaults(false);
    let result = restored.load_with_notify(&manifest, false);
    assert_eq!(
        restored.entity_local_translation(result.selected_entity_id.expect("selection")),
        Some(authored)
    );
    assert!(persistence.apply_playback_state(PlaybackState::Stopped));
    assert_eq!(scene.entity_local_translation(id), Some(authored));
    assert!(!persistence.physics_play_snapshot_path().exists());
    assert!(!store.scene_dirty());
}

#[test]
fn discarding_suppresses_only_the_current_revision() {
    let project = TempProject::new();
    let (persistence, scene, _) = project.session();
    let id = scene.default_selection_id().expect("entity");
    scene.set_entity_local_translation(id, Float3::new(2.0, 3.0, 4.0));
    persistence.autosave_scene_if_needed(10.0, true);
    assert!(persistence.autosave_path().is_file());
    persistence.discard_autosaved_scene();
    persistence.autosave_scene_if_needed(10.0, true);
    assert!(!persistence.autosave_path().exists());
    scene.set_entity_local_translation(id, Float3::new(5.0, 6.0, 7.0));
    persistence.autosave_scene_if_needed(10.0, true);
    assert!(persistence.autosave_path().exists());
}
