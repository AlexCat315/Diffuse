//! Core preview cases from `MeshInsetTests.swift`.

use std::collections::BTreeSet;
use std::fs;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::polygon_mesh::GeometryLimits;
use diffuse_math::simd::simd_compat::Float3;

use super::mesh_editing_tests::MeshProject;
use crate::application::persistence::scene_persistence::EditorScenePersistence;
use crate::geometry::editor_mesh_picker::EditorMeshSelectionMode as Mode;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::state::editor_store::EditorStore;

fn project() -> MeshProject {
    let project = MeshProject::new();
    assert!(project.editing.set_mode(Mode::Face));
    project.select([1]);
    project
}

#[test]
fn inset_keeps_cap_selection_and_publishes_one_disk_edit() {
    let project = project();
    let model = &project.editing;
    let source = model.control_mesh().expect("source mesh");
    let path = project.path();
    let before = fs::read(&path).expect("source bytes");
    assert!(model.begin_inset());
    assert!(model.preview_inset(0.2));
    assert!(model.preview_inset(0.1));
    model.synchronize();
    assert_eq!(model.selection(), BTreeSet::from([1]));
    assert_eq!(
        model.control_mesh().expect("preview mesh").positions.len(),
        12
    );
    assert_eq!(fs::read(&path).expect("source bytes"), before);
    assert!(!model.triangulate_selection() && !model.extrude_region() && !model.begin_transform());
    model.select_all();
    model.invert_selection();
    assert_eq!(model.selection(), BTreeSet::from([1]));
    assert!(model.commit_inset());
    let inset = model.control_mesh().expect("edited mesh");
    assert_eq!(inset.faces.len(), 10);
    assert_eq!(model.selection(), BTreeSet::from([1]));
    assert_eq!(
        GeometryDocument::load(&path)
            .expect("saved mesh")
            .source
            .evaluate(GeometryLimits::default())
            .expect("mesh"),
        inset
    );
    assert!(project.scene.undo_edit());
    model.synchronize();
    assert_eq!(model.control_mesh(), Some(source));
    assert!(project.scene.redo_edit());
    model.synchronize();
    assert_eq!(model.control_mesh(), Some(inset));
    project.select([1]);
    model.extrusion_distance.set(-0.2);
    assert!(model.extrude_region());
    assert_eq!(
        model.control_mesh().expect("inset extrusion").faces.len(),
        14
    );
}

#[test]
fn invalid_width_keeps_the_last_preview_and_prevents_confirmation() {
    let project = project();
    let model = &project.editing;
    let path = project.path();
    let before = fs::read(&path).expect("source bytes");
    assert!(model.begin_inset());
    assert!(model.preview_inset(0.2));
    let valid = model.control_mesh();
    assert!(!model.preview_inset(2.0));
    assert!(!model.is_inset_preview_valid());
    assert_eq!(model.inset_distance(), 2.0);
    assert_eq!(model.control_mesh(), valid);
    assert!(!model.commit_interactive_edit());
    assert!(
        project
            .persistence()
            .save_scene_manifest(Some(model))
            .is_none()
    );
    assert!(model.is_insetting() && project.authoring.has_interactive_edit());
    assert_eq!(fs::read(&path).expect("source bytes"), before);
    assert!(model.preview_inset(0.15));
    assert!(model.is_inset_preview_valid());
    assert!(model.cancel_inset());
    assert_eq!(model.control_mesh().expect("source mesh").faces.len(), 6);
}

#[test]
fn saving_commits_the_inset_and_keeps_it_after_reopening() {
    let project = project();
    let model = &project.editing;
    assert!(model.begin_inset());
    assert!(model.preview_inset(0.15));
    let persistence = project.persistence();
    let saved = persistence
        .save_scene_manifest(Some(model))
        .expect("saved scene");
    assert!(!model.has_interactive_edit());
    let document = GeometryDocument::load(&project.path()).expect("committed geometry");
    assert_eq!(
        document
            .source
            .evaluate(GeometryLimits::default())
            .expect("geometry")
            .faces
            .len(),
        10
    );
    let restored = EditorSceneAdapter::with_defaults(false);
    let reopened = EditorScenePersistence::new(
        saved
            .parent()
            .expect(".cove")
            .parent()
            .expect("project")
            .to_path_buf(),
        restored.clone(),
        std::rc::Rc::new(EditorStore::new()),
    );
    assert!(
        reopened
            .open_scene_manifest(&saved, true, true, |manifest| reopened.load_scene(manifest))
            .is_some()
    );
    let id = restored.roots()[0].id;
    let asset = restored.referenced_asset(id).expect("reopened asset");
    assert_eq!(
        GeometryDocument::load(&asset.absolute_path).expect("reopened geometry"),
        document
    );
}

#[test]
fn cancel_mode_change_and_leaving_keep_the_inset_out_of_history() {
    let project = project();
    let model = &project.editing;
    let path = project.path();
    let before = fs::read(&path).expect("source bytes");
    assert!(model.begin_inset());
    assert!(model.cancel_interactive_edit());
    assert!(!model.has_interactive_edit() && !project.authoring.has_interactive_edit());
    assert_eq!(model.selection(), BTreeSet::from([1]));
    assert_eq!(model.control_mesh().expect("source mesh").faces.len(), 6);
    assert!(model.begin_inset());
    assert!(model.set_mode(Mode::Edge));
    assert!(!model.has_interactive_edit());
    assert_eq!(model.control_mesh().expect("source mesh").faces.len(), 6);
    assert!(model.set_mode(Mode::Face));
    project.select([1]);
    assert!(model.begin_inset());
    model.leave();
    assert!(!model.has_interactive_edit() && !project.authoring.has_interactive_edit());
    assert_eq!(fs::read(&path).expect("source bytes"), before);
    assert!(project.scene.undo_edit());
    assert_eq!(
        GeometryDocument::load(&path).expect("source").source,
        GeometrySource::Box { size: Float3::ONE }
    );
}

#[test]
fn externally_edited_asset_survives_a_stale_inset_confirmation() {
    let project = project();
    let path = project.path();
    let model = &project.editing;
    assert!(model.begin_inset());
    let mut external = GeometryDocument::load(&path).expect("source");
    external.name = "External".into();
    external
        .save(&path, GeometryLimits::default())
        .expect("external save");
    assert!(!model.commit_inset());
    assert!(!model.has_interactive_edit() && !project.authoring.has_interactive_edit());
    assert_eq!(
        GeometryDocument::load(&path).expect("external source"),
        external
    );
}

#[test]
fn cancelling_an_inset_after_external_topology_changes_clears_selection() {
    let project = project();
    let path = project.path();
    let model = &project.editing;
    let slot = project
        .scene
        .referenced_asset(project.id)
        .expect("asset")
        .mesh_index;
    assert!(model.begin_inset());
    let mut external = GeometryDocument::load(&path).expect("source");
    let limits = GeometryLimits::default();
    let mut mesh = external.source.evaluate(limits).expect("mesh");
    let empty = BTreeSet::new();
    mesh.delete(
        &empty,
        &BTreeSet::new(),
        &(0..mesh.faces.len() as i64).collect(),
        limits,
    )
    .expect("delete faces");
    external.source = GeometrySource::Polygon { mesh: mesh.clone() };
    external.save(&path, limits).expect("external save");
    assert!(model.cancel_inset());
    assert!(model.selection().is_empty());
    assert_eq!(model.control_mesh(), Some(mesh));
    assert_eq!(
        AssetRegistry::shared()
            .mesh_asset(slot)
            .expect("mesh asset")
            .triangle_count(),
        0
    );
    assert!(!project.authoring.has_interactive_edit());
}
