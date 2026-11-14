//! Test fixture and core interaction cases from `MeshEditingTests.swift`.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_document::GeometryDocument;
use diffuse_assets::geometry::geometry_modifier::GeometryModifier;
use diffuse_assets::geometry::polygon_mesh::GeometryLimits;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4};

use crate::geometry::editor_geometry_authoring::{EditorGeometryAuthoring, EditorGeometryPreset};
use crate::geometry::editor_mesh_editing::{EditorMeshEditing, EditorMeshExtrusionDirection};
use crate::geometry::editor_mesh_picker::EditorMeshSelectionMode as Mode;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::state::editor_store::EditorStore;
use crate::workstation::documents::EditorDocumentWorkspace;

pub(super) struct MeshProject {
    root: PathBuf,
    pub scene: EditorSceneAdapter,
    pub store: Rc<EditorStore>,
    pub authoring: Rc<EditorGeometryAuthoring>,
    pub editing: Rc<EditorMeshEditing>,
    pub id: u64,
}

impl MeshProject {
    pub fn new() -> Self {
        let root = std::env::temp_dir().join(format!("mesh-edit-{}", diffuse_kernel::codable::new_uuid()));
        fs::create_dir(&root).expect("project directory");
        let scene = EditorSceneAdapter::with_defaults(false);
        let store = Rc::new(EditorStore::new());
        let authoring = EditorGeometryAuthoring::new(
            root.clone(), scene.clone(), store.clone(), Arc::new(EditorDocumentWorkspace::new(&root)),
            Rc::new(|| {}),
        );
        let editing = EditorMeshEditing::new(authoring.clone(), scene.clone(), store.clone(), Rc::new(|| {}));
        let id = authoring.create(EditorGeometryPreset::Box).expect("unit box");
        Self { root, scene, store, authoring, editing, id }
    }

    pub fn path(&self) -> String {
        self.scene.referenced_asset(self.id).expect("geometry asset").absolute_path
    }

    pub fn select(&self, indices: impl IntoIterator<Item = usize>) {
        self.editing.select(indices.into_iter().collect(), false, false);
    }

    pub fn document(&self) -> GeometryDocument {
        self.authoring.document(self.id).expect("load geometry").expect("geometry asset")
    }
}

impl Drop for MeshProject {
    fn drop(&mut self) {
        self.editing.leave();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn translation(x: f32, y: f32) -> Float4x4 {
    let mut delta = MATRIX_IDENTITY_FLOAT4X4;
    delta.set_column(3, Float4::new(x, y, 0.0, 1.0));
    delta
}

#[test]
fn selection_modes_resolve_vertices_and_clear_stale_topology_selection() {
    let project = MeshProject::new();
    let model = &project.editing;
    assert!(model.set_mode(Mode::Vertex));
    project.select([0, 1, 99]);
    assert_eq!(model.selection(), BTreeSet::from([0, 1]));
    assert_eq!(model.selected_vertices(), BTreeSet::from([0, 1]));
    assert!(model.set_mode(Mode::Edge));
    project.select([0]);
    let edge = model.picker().expect("picker").edges[0];
    assert_eq!(model.selected_vertices(), BTreeSet::from([edge.a, edge.b]));
    assert!(model.set_mode(Mode::Face));
    project.select([3]);
    assert_eq!(model.selected_vertices().len(), 4);
    let before = model.control_mesh().expect("control mesh");
    assert!(model.extrude_region());
    assert_eq!(model.control_mesh().expect("extruded mesh").faces.len(), before.faces.len() + 4);
    assert_eq!(model.selection(), BTreeSet::from([3]));
    assert!(project.scene.undo_edit());
    model.synchronize();
    assert_eq!(model.control_mesh(), Some(before));
    assert!(model.selection().is_empty());
    assert!(project.scene.inspector_sections(Some(project.id)).iter().any(|section| section.id == "mesh-edit-selection"));
}

#[test]
fn a_closed_face_selection_can_extrude_along_an_explicit_axis() {
    let project = MeshProject::new();
    let model = &project.editing;
    assert!(model.set_mode(Mode::Face));
    model.select_all();
    model.extrusion_direction.set(EditorMeshExtrusionDirection::Y);
    model.extrusion_distance.set(1.0);
    assert!(model.extrude_region());
    let mesh = model.control_mesh().expect("control mesh");
    assert_eq!(mesh.faces.len(), 6);
    assert_eq!(project.document().evaluate(GeometryLimits::default()).expect("baked extrusion").mesh.local_bounds().1.y, 1.5);
}

#[test]
fn drag_previews_leave_file_and_history_untouched_until_one_commit() {
    let project = MeshProject::new();
    let model = &project.editing;
    assert!(model.set_mode(Mode::Vertex));
    model.select_all();
    let path = project.path();
    let original = fs::read(&path).expect("original file");
    let source = model.control_mesh().expect("control mesh");
    assert!(model.begin_transform());
    assert!(model.preview_transform(translation(0.2, 0.0)));
    assert!(model.preview_transform(translation(0.4, 0.0)));
    assert_eq!(model.control_mesh().expect("preview mesh").positions[0], source.positions[0] + Float3::new(0.4, 0.0, 0.0));
    assert_eq!(fs::read(&path).expect("file during preview"), original);
    let asset = project.scene.referenced_asset(project.id).expect("geometry asset");
    let maximum = || AssetRegistry::shared().mesh_asset(asset.mesh_index).expect("mesh").local_bounds().1.x;
    assert!((maximum() - 0.9).abs() < 1e-6);
    assert!(model.cancel_interactive_edit());
    assert!(!model.is_transforming() && !project.authoring.has_interactive_edit());
    assert_eq!(model.control_mesh(), Some(source));
    assert_eq!(maximum(), 0.5);
    assert_eq!(fs::read(&path).expect("file after cancellation"), original);
    assert!(project.scene.undo_edit());
    model.synchronize();
    assert!(!model.is_editing());
}

#[test]
fn one_drag_commits_as_one_reversible_asset_edit_and_retains_modifiers() {
    let project = MeshProject::new();
    assert!(project.authoring.add_modifier(GeometryModifier::Array { count: 2, offset: Float3::new(2.0, 0.0, 0.0) }, project.id));
    let model = &project.editing;
    assert!(model.set_mode(Mode::Vertex));
    model.select_all();
    let original = project.document();
    assert!(model.begin_transform());
    assert!(model.preview_transform(translation(0.0, 0.2)));
    assert!(model.preview_transform(translation(0.0, 0.5)));
    assert!(model.finish_transform());
    let final_document = project.document();
    assert_eq!(final_document.modifiers, original.modifiers);
    assert_eq!(final_document.evaluate(GeometryLimits::default()).expect("evaluated edit").mesh.local_bounds().1.y, 1.0);
    assert!(project.scene.undo_edit());
    assert_eq!(project.document(), original);
    assert!(project.scene.redo_edit());
    assert_eq!(project.document(), final_document);
}

#[test]
fn an_external_change_during_a_drag_is_preserved() {
    let project = MeshProject::new();
    let model = &project.editing;
    assert!(model.set_mode(Mode::Vertex));
    model.select_all();
    assert!(model.begin_transform());
    assert!(model.preview_transform(translation(0.0, 1.0)));
    let asset = project.scene.referenced_asset(project.id).expect("asset");
    let mut external = GeometryDocument::load(&asset.absolute_path).expect("saved file");
    external.name = "External".into();
    external.save(&asset.absolute_path, GeometryLimits::default()).expect("external edit");
    assert!(!model.finish_transform());
    assert_eq!(GeometryDocument::load(&asset.absolute_path).expect("saved file"), external);
    assert_eq!(AssetRegistry::shared().mesh_asset(asset.mesh_index).expect("mesh").name, "External");
    assert!(!project.authoring.has_interactive_edit());
}
