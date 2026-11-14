//! Persistence cases from `EditorSceneRecoveryTests.swift`.

use std::fs;
use std::path::PathBuf;
use std::rc::Rc;

use diffuse_assets::swift_json::to_sorted_pretty;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::runtime_world::LocalTransform;

use crate::application::persistence::scene_persistence::EditorScenePersistence;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};
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
    let (target, scene, store) = project.session();
    let reopened = target.open_scene_manifest(&external, true, true, |manifest| {
        target.load_scene(manifest)
    });
    assert_eq!(reopened, Some(manifest));
    assert_eq!(
        scene.entity_local_translation(store.selected_entity_id().expect("selection")),
        Some(position)
    );
    assert!(!store.scene_dirty());
    assert_eq!(
        target.save_scene_manifest(None),
        Some(target.scene_manifest_path())
    );
    assert!(target.scene_manifest_path().is_file());
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
fn forced_autosave_restores_a_dirty_scene_and_explicit_save_clears_recovery() {
    let project = TempProject::new();
    let (source, scene, store) = project.session();
    let id = scene.default_selection_id().expect("entity");
    let edited = scene.entity_local_translation(id).expect("original") + Float3::new(4.0, 5.0, 6.0);
    scene.set_entity_local_translation(id, edited);
    assert!(store.scene_dirty());
    source.autosave_scene_if_needed(EditorScenePersistence::AUTOSAVE_INTERVAL, true);
    assert!(source.autosave_path().is_file());
    let (target, scene, store) = project.session();
    assert!(
        target
            .restore_project_scene_at_launch(|manifest| target.load_scene(manifest))
            .is_some()
    );
    assert_eq!(
        scene.entity_local_translation(store.selected_entity_id().expect("selection")),
        Some(edited)
    );
    assert!(store.scene_dirty() && store.scene_recovery_pending());
    assert!(target.save_scene_manifest(None).is_some());
    assert!(!store.scene_dirty());
    assert!(!target.autosave_path().exists());
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
