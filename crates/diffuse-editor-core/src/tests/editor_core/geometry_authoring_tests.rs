//! `Editor/Tests/EditorCoreTests/GeometryAuthoringTests.swift`.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use diffuse_assets::asset_registry::{AssetRegistry, ImportableAssetKind};
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_modifier::GeometryModifier;
use diffuse_assets::geometry::polygon_mesh::GeometryLimits;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::physics::queries::spatial_queries::MeshColliderBoundsResource;

use crate::assets::asset_catalog::EditorAssetCatalog;
use crate::assets::editor_asset_file_workflow::EditorAssetFileWorkflow;
use crate::geometry::editor_geometry_authoring::{EditorGeometryAuthoring, EditorGeometryPreset};
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::EditorInspectorFieldValue;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::PlaybackState;
use crate::state::editor_store::EditorStore;
use crate::workstation::documents::EditorDocumentWorkspace;

struct Project {
    root: PathBuf,
    scene: EditorSceneAdapter,
    store: Rc<EditorStore>,
    documents: Arc<EditorDocumentWorkspace>,
    authoring: Rc<EditorGeometryAuthoring>,
}

impl Project {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "dcc-geometry-{}",
            diffuse_kernel::codable::new_uuid()
        ));
        fs::create_dir(&root).expect("project directory");
        let scene = EditorSceneAdapter::with_defaults(false);
        let store = Rc::new(EditorStore::new());
        let documents = Arc::new(EditorDocumentWorkspace::new(&root));
        let authoring = EditorGeometryAuthoring::new(
            root.clone(),
            scene.clone(),
            store.clone(),
            documents.clone(),
            Rc::new(|| {}),
        );
        Self {
            root,
            scene,
            store,
            documents,
            authoring,
        }
    }

    fn create_box(&self) -> u64 {
        self.authoring
            .create(EditorGeometryPreset::Box)
            .expect("create geometry")
    }

    fn document(&self, entity: u64) -> GeometryDocument {
        self.authoring
            .document(entity)
            .expect("read geometry")
            .expect("referenced geometry")
    }

    fn add_subdivision(&self, entity: u64) -> bool {
        self.authoring
            .add_modifier(GeometryModifier::Subdivision { levels: 1 }, entity)
    }

    fn collider_max_x(&self, slot: i64) -> Option<f32> {
        self.scene
            .scene()
            .resource::<MeshColliderBoundsResource>()?
            .bounds_by_resource_id
            .get(&format!("meshIndex:{slot}"))
            .map(|bound| bound.max.x)
    }
}

impl Drop for Project {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn presets_create_assets_scene_objects_and_inspector_controls() {
    for preset in EditorGeometryPreset::ALL {
        let project = Project::new();
        let id = project.authoring.create(preset).expect("create geometry");
        let asset = project.scene.referenced_asset(id).expect("asset");
        assert_eq!(asset.kind, ImportableAssetKind::Dmesh, "{preset:?}");
        assert!(Path::new(&asset.absolute_path).is_file(), "{preset:?}");
        assert_eq!(project.store.selected_entity_id(), Some(id), "{preset:?}");
        assert_eq!(
            project.document(id).source,
            preset.document().source,
            "{preset:?}"
        );
        let sections = project.scene.inspector_sections(Some(id));
        for expected in [
            "geometry-source",
            "geometry-modifiers",
            "geometry-material-0",
        ] {
            assert!(
                sections.iter().any(|section| section.id == expected),
                "{preset:?}, {expected}"
            );
        }
        assert!(project.scene.undo_edit());
        assert!(project.scene.entity_summary(Some(id)).is_none());
        assert!(project.scene.redo_edit());
        assert!(project.scene.entity_summary(Some(id)).is_some());
    }
}

#[test]
fn geometry_and_transform_history_refresh_derived_collision_geometry() {
    let project = Project::new();
    let id = project.create_box();
    let slot = project
        .scene
        .referenced_asset(id)
        .expect("asset")
        .mesh_index;
    let translation = Float3::new(3.0, 0.0, 0.0);
    assert!(project.authoring.add_modifier(
        GeometryModifier::Array {
            count: 2,
            offset: Float3::new(2.0, 0.0, 0.0),
        },
        id
    ));
    project.scene.set_entity_local_translation(id, translation);

    assert!(project.scene.undo_edit());
    assert_eq!(
        project.scene.entity_local_translation(id),
        Some(Float3::ZERO)
    );
    assert_eq!(project.document(id).modifiers.len(), 1);
    assert_eq!(project.collider_max_x(slot), Some(2.5));
    assert!(project.scene.undo_edit());
    assert!(project.document(id).modifiers.is_empty());
    assert_eq!(project.collider_max_x(slot), Some(0.5));
    assert!(project.scene.redo_edit());
    assert_eq!(project.document(id).modifiers.len(), 1);
    assert_eq!(project.collider_max_x(slot), Some(2.5));
    assert!(project.scene.redo_edit());
    assert_eq!(
        project.scene.entity_local_translation(id),
        Some(translation)
    );
    assert_eq!(project.collider_max_x(slot), Some(2.5));
}

#[test]
fn inspector_edits_follow_modifier_identities_across_reordering_and_removal() {
    let project = Project::new();
    let id = project.create_box();
    let source = project
        .scene
        .inspector_sections(Some(id))
        .into_iter()
        .find(|section| section.id == "geometry-source")
        .expect("source section");
    let size = source
        .fields
        .into_iter()
        .find(|field| field.id == "geometry-size")
        .expect("size");
    let EditorInspectorFieldValue::Vector3 { x, .. } = size.value else {
        panic!("expected size control");
    };
    x.set(3.0);
    assert_eq!(
        project.document(id).source,
        GeometrySource::Box {
            size: Float3::new(3.0, 1.0, 1.0)
        }
    );
    assert!(project.add_subdivision(id));
    let offset = Float3::new(4.0, 0.0, 0.0);
    assert!(
        project
            .authoring
            .add_modifier(GeometryModifier::Array { count: 2, offset }, id)
    );
    let document = project.document(id);
    let first = &document.modifiers[0].id;
    let second = &document.modifiers[1].id;
    let section = project
        .authoring
        .inspector_sections(id)
        .into_iter()
        .find(|section| section.id == format!("geometry-modifier-{second}"))
        .expect("array section");
    let count = section
        .fields
        .into_iter()
        .find(|field| field.id == format!("{second}-count"))
        .expect("count");
    let EditorInspectorFieldValue::ConstrainedNumber { binding, .. } = count.value else {
        panic!("expected array count control");
    };
    assert!(project.authoring.move_modifier(second, -1, id));
    binding.set(3.0);
    let reordered = project.document(id);
    assert_eq!(
        reordered
            .modifiers
            .iter()
            .map(|entry| &entry.id)
            .collect::<Vec<_>>(),
        [second, first]
    );
    assert_eq!(
        reordered.modifiers[0].operation,
        GeometryModifier::Array { count: 3, offset }
    );
    assert!(project.authoring.remove_modifier(second, id));
    binding.set(4.0);
    assert_eq!(
        project.document(id).modifiers[0].operation,
        GeometryModifier::Subdivision { levels: 1 }
    );
}

#[test]
fn applying_through_a_modifier_preserves_evaluated_vertices_and_is_reversible() {
    let project = Project::new();
    let id = project.create_box();
    assert!(project.add_subdivision(id));
    assert!(project.authoring.add_modifier(
        GeometryModifier::Array {
            count: 2,
            offset: Float3::new(2.0, 0.0, 0.0)
        },
        id
    ));
    let before = project.document(id);
    let limits = GeometryLimits::default();
    let vertices = before
        .evaluate(limits)
        .expect("original mesh")
        .mesh
        .vertices;
    assert!(
        project
            .authoring
            .apply_modifier(&before.modifiers[0].id, id)
    );
    let after = project.document(id);
    assert_eq!(after.modifiers.len(), 1);
    let GeometrySource::Polygon { mesh } = &after.source else {
        panic!("expected editable control topology");
    };
    assert_eq!(mesh.faces.len(), 24);
    assert_eq!(
        after.evaluate(limits).expect("applied mesh").mesh.vertices,
        vertices
    );
    assert!(project.scene.undo_edit());
    assert_eq!(project.document(id), before);
}

#[test]
fn invalid_edits_and_conflicting_history_preserve_files_and_history() {
    let project = Project::new();
    let id = project.create_box();
    let asset = project.scene.referenced_asset(id).expect("asset");
    let path = &asset.absolute_path;
    let original = fs::read(path).expect("original file");
    assert!(!project.authoring.edit(id, |doc| {
        doc.source = GeometrySource::Box { size: Float3::ZERO };
        Ok(())
    }));
    assert_eq!(fs::read(path).expect("unchanged file"), original);
    let selection = BTreeSet::from([id]);
    project.scene.set_entity_locked(true, &selection);
    assert!(!project.add_subdivision(id));
    project.scene.set_entity_locked(false, &selection);
    assert!(project.add_subdivision(id));
    let expected = project.document(id);
    let mut external = expected.clone();
    external.name = "External change".into();
    external
        .save(path, GeometryLimits::default())
        .expect("external save");
    assert!(!project.scene.undo_edit());
    assert_eq!(
        GeometryDocument::load(path).expect("external file"),
        external
    );
    assert!(project.scene.can_undo_edit());
    assert!(!project.scene.can_redo_edit());
    expected
        .save(path, GeometryLimits::default())
        .expect("restore expected file");
    assert!(project.scene.undo_edit());
    assert!(project.document(id).modifiers.is_empty());
    assert!(project.scene.can_redo_edit());
}

#[test]
fn geometry_history_follows_a_rename_and_scene_save_and_reopen() {
    let project = Project::new();
    let id = project.create_box();
    assert!(project.add_subdivision(id));
    let asset = project.scene.referenced_asset(id).expect("asset");
    let new_id = "Assets/Geometry/Renamed.dmesh";
    EditorAssetFileWorkflow::relocate(
        Path::new(&asset.absolute_path),
        &project.root.join(new_id),
        &project.root,
    )
    .expect("rename asset");
    AssetRegistry::shared().relocate_asset_path(&asset.id, new_id);
    let assets =
        EditorAssetCatalog::load_project_default(project.root.to_str().expect("project path"))
            .expect("index renamed asset");
    let renamed = assets
        .iter()
        .find(|asset| asset.id == new_id)
        .expect("renamed asset");
    project.scene.relocate_asset_references(&asset.id, renamed);
    assert!(project.scene.undo_edit());
    assert!(project.document(id).modifiers.is_empty());
    assert!(project.scene.redo_edit());
    assert_eq!(
        project
            .scene
            .referenced_asset(id)
            .expect("renamed reference")
            .mesh_index,
        asset.mesh_index
    );

    let file = project.root.join("scene.json");
    let manifest = project.scene.manifest();
    fs::write(
        &file,
        diffuse_assets::swift_json::to_sorted_pretty(&manifest).expect("scene JSON"),
    )
    .expect("save scene");
    project.scene.reset_to_preview_scene();
    let manifest: EditorSceneManifest =
        serde_json::from_slice(&fs::read(file).expect("saved scene")).expect("read scene manifest");
    let result = project.scene.load(&manifest);
    assert!(result.error.is_none());
    let reopened = project.scene.roots().first().expect("scene root").id;
    assert_eq!(project.document(reopened).modifiers.len(), 1);
}

#[test]
fn unsaved_text_drafts_and_playback_reject_geometry_writes() {
    let project = Project::new();
    let id = project.create_box();
    let asset = project.scene.referenced_asset(id).expect("asset");
    let original = fs::read_to_string(&asset.absolute_path).expect("asset text");
    project.documents.open(&asset.relative_path);
    project
        .documents
        .edit(&asset.relative_path, &format!("{original}\n"));
    assert!(project.documents.has_unsaved_changes());
    assert!(!project.add_subdivision(id));
    assert_eq!(
        fs::read_to_string(&asset.absolute_path).expect("unchanged file"),
        original
    );
    project
        .documents
        .reload_with_discard(&asset.relative_path, true);
    project
        .store
        .dispatch(EditorAction::SetPlaybackState(PlaybackState::Playing));
    assert!(!project.add_subdivision(id));
    assert_eq!(project.authoring.create(EditorGeometryPreset::Box), None);
    project
        .store
        .dispatch(EditorAction::SetPlaybackState(PlaybackState::Stopped));
    assert!(project.add_subdivision(id));
}

#[test]
fn interactive_previews_restart_from_the_original_and_refresh_the_picker() {
    let project = Project::new();
    let id = project.create_box();
    let path = project
        .scene
        .referenced_asset(id)
        .expect("asset")
        .absolute_path;
    let original = fs::read(&path).expect("original file");
    let picker = project.authoring.viewport_picker(id).expect("picker");
    assert!(project.authoring.begin_interactive_edit(id));
    for delta in [1.0, 2.0] {
        assert!(project.authoring.preview_interactive_edit(|doc| {
            if let GeometrySource::Box { size } = &mut doc.source {
                size.x += delta;
            }
            Ok(())
        }));
    }
    assert_eq!(
        project.document(id).source,
        GeometrySource::Box {
            size: Float3::new(3.0, 1.0, 1.0)
        }
    );
    let preview = project
        .authoring
        .viewport_picker(id)
        .expect("preview picker");
    assert!(!Rc::ptr_eq(&picker, &preview));
    assert_eq!(preview.positions[1].x, 1.5);
    assert_eq!(fs::read(&path).expect("original file"), original);
    assert!(project.authoring.cancel_interactive_edit());
    assert_eq!(
        project.document(id).source,
        EditorGeometryPreset::Box.document().source
    );
    assert_eq!(
        project
            .authoring
            .viewport_picker(id)
            .expect("restored picker")
            .positions[1]
            .x,
        0.5
    );

    assert!(project.authoring.begin_interactive_edit(id));
    assert!(project.authoring.preview_interactive_edit(|doc| {
        doc.name = "Edited in preview".into();
        Ok(())
    }));
    assert!(project.authoring.commit_interactive_edit());
    assert_eq!(
        GeometryDocument::load(&path)
            .expect("committed document")
            .name,
        "Edited in preview"
    );
    assert!(project.scene.undo_edit());
    assert_eq!(fs::read(path).expect("restored file"), original);
}
