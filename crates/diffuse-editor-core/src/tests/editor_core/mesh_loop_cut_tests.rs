//! Core preview cases from `MeshLoopCutTests.swift`.

use std::fs;

use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_modifier::GeometryModifier;
use diffuse_assets::geometry::polygon_mesh::{GeometryLimits, PolygonMeshEdge};

use super::mesh_editing_tests::MeshProject;
use crate::application::persistence::scene_persistence::EditorScenePersistence;
use crate::geometry::editor_mesh_picker::EditorMeshSelectionMode as Mode;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::state::editor_store::EditorStore;

fn project() -> MeshProject {
    let project = MeshProject::new();
    assert!(project.editing.set_mode(Mode::Edge));
    let seed = project
        .editing
        .picker()
        .expect("picker")
        .edges
        .iter()
        .position(|&edge| edge == PolygonMeshEdge::new(0, 1))
        .expect("seed edge");
    project.select([seed]);
    project
}

#[test]
fn count_and_slide_previews_commit_one_edit_with_the_new_loops_selected() {
    let project = project();
    let model = &project.editing;
    let source = model.control_mesh().expect("source");
    let path = project.path();
    let before = fs::read(&path).expect("source file");
    assert!(
        project
            .authoring
            .add_modifier(GeometryModifier::Subdivision { levels: 1 }, project.id)
    );
    let modifiers = project.document().modifiers;
    let modified = fs::read(&path).expect("modified file");
    assert!(model.begin_loop_cut());
    assert_eq!(model.selection().len(), 4);
    assert!(model.preview_loop_cut(3, -0.5));
    assert!(model.preview_loop_cut(2, 0.25));
    model.synchronize();
    assert_eq!(model.selection().len(), 8);
    assert_eq!(model.control_mesh().expect("preview").positions.len(), 16);
    assert_eq!(fs::read(&path).expect("preview file"), modified);
    assert_ne!(modified, before);
    assert!(!model.begin_transform() && !model.delete_selection() && !model.apply_modifiers());
    assert!(model.commit_loop_cut());
    let final_mesh = model.control_mesh().expect("final mesh");
    assert_eq!(final_mesh.faces.len(), 14);
    assert_eq!(model.selection().len(), 8);
    assert!(!model.has_interactive_edit());
    assert_eq!(
        GeometryDocument::load(&path)
            .expect("committed file")
            .source
            .evaluate(GeometryLimits::default())
            .expect("mesh"),
        final_mesh
    );
    assert_eq!(project.document().modifiers, modifiers);
    assert!(project.scene.undo_edit());
    model.synchronize();
    assert_eq!(model.control_mesh(), Some(source));
    assert!(project.scene.redo_edit());
    model.synchronize();
    assert_eq!(model.control_mesh(), Some(final_mesh));
}

#[test]
fn invalid_cut_parameters_keep_the_valid_preview_and_prevent_confirmation() {
    let project = project();
    let model = &project.editing;
    let path = project.path();
    let before = fs::read(&path).expect("source file");
    assert!(model.begin_loop_cut());
    let preview = model.control_mesh();
    assert!(!model.preview_loop_cut(0, 0.0));
    assert!(!model.is_loop_cut_preview_valid());
    assert_eq!(model.control_mesh(), preview);
    assert!(!model.commit_interactive_edit());
    assert!(
        project
            .persistence()
            .save_scene_manifest(Some(model))
            .is_none()
    );
    assert!(!model.preview_loop_cut(2, 1.0));
    assert_eq!(fs::read(&path).expect("preview file"), before);
    assert!(model.preview_loop_cut(2, -0.4));
    assert!(model.cancel_loop_cut());
    assert_eq!(model.selection().len(), 1);
    assert_eq!(
        model.control_mesh().expect("restored source").faces.len(),
        6
    );
}

#[test]
fn saving_commits_the_loop_cut_and_keeps_it_after_reopening() {
    let project = project();
    let model = &project.editing;
    assert!(model.begin_loop_cut());
    assert!(model.preview_loop_cut(3, 0.2));
    let saved = project
        .persistence()
        .save_scene_manifest(Some(model))
        .expect("saved scene");
    let document = GeometryDocument::load(&project.path()).expect("committed geometry");
    assert!(!model.has_interactive_edit());
    assert_eq!(model.selection().len(), 12);
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
fn cancelling_or_changing_mode_restores_the_seed_topology() {
    let project = project();
    let model = &project.editing;
    let seed = model.selection();
    let path = project.path();
    let before = fs::read(&path).expect("source file");
    assert!(model.begin_loop_cut());
    assert!(model.cancel_interactive_edit());
    assert_eq!(model.selection(), seed);
    assert!(!model.has_interactive_edit() && !project.authoring.has_interactive_edit());
    assert!(model.begin_loop_cut());
    assert!(model.set_mode(Mode::Face));
    assert!(!model.has_interactive_edit());
    assert_eq!(
        model.control_mesh().expect("restored source").faces.len(),
        6
    );
    assert_eq!(fs::read(&path).expect("source file"), before);
}

#[test]
fn external_changes_survive_confirmation_and_triangles_reject_loop_cut() {
    let project = project();
    let model = &project.editing;
    let seed = model.selection();
    let path = project.path();
    assert!(model.begin_loop_cut());
    let mut external = GeometryDocument::load(&path).expect("read source");
    external.name = "External".into();
    let limits = GeometryLimits::default();
    external.save(&path, limits).expect("external save");
    assert!(!model.commit_loop_cut());
    assert_eq!(model.selection(), seed);
    assert!(!model.has_interactive_edit() && !project.authoring.has_interactive_edit());
    assert_eq!(
        GeometryDocument::load(&path).expect("read source"),
        external
    );
    assert!(project.authoring.edit(project.id, |document| {
        let mut mesh = document.source.evaluate(limits)?;
        mesh.triangulate_faces(&(0..mesh.faces.len() as i64).collect(), limits)?;
        document.source = GeometrySource::Polygon { mesh };
        Ok(())
    }));
    model.synchronize();
    project.select([0]);
    let before = fs::read(&path).expect("read triangulated file");
    assert!(!model.begin_loop_cut());
    assert!(!model.has_interactive_edit() && !project.authoring.has_interactive_edit());
    assert_eq!(fs::read(&path).expect("read triangulated file"), before);
}
