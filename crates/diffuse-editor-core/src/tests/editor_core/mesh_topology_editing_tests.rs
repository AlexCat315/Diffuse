//! `Editor/Tests/EditorCoreTests/MeshTopologyEditingTests.swift`.
//!
//! Component deletion across vertex/edge/face modes, the empty-mesh branch that
//! must keep modifiers and collision data consistent across a reopen, dissolve
//! against triangulated faces, and the failure paths that leave the file and
//! history untouched.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use std::rc::Rc;

use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_modifier::GeometryModifier;
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{GeometryLimits, PolygonMesh};
use diffuse_math::simd::simd_compat::{Float2, Float3, Int2};
use diffuse_scene::physics::queries::spatial_queries::{
    MeshColliderBoundsResource, MeshColliderGeometryResource,
};

use crate::application::editor_application::{EditorApplication, EditorApplicationOptions};
use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
use crate::geometry::editor_geometry_authoring::EditorGeometryPreset;
use crate::geometry::editor_mesh_picker::EditorMeshSelectionMode;
use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

struct TopologyProject {
    root: PathBuf,
}

impl TopologyProject {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "topology-edit-{}",
            diffuse_kernel::codable::new_uuid()
        ));
        fs::create_dir_all(&root).expect("project directory");
        TopologyProject { root }
    }

    fn launch(&self) -> Rc<EditorApplication> {
        EditorApplication::with_options(
            self.root.to_string_lossy().into_owned(),
            EditorApplicationOptions {
                seed_preview_scene: false,
                ..EditorApplicationOptions::default()
            },
        )
        .expect("launch editor")
    }

    /// Mirrors Swift's `withApp`: a fresh box, then the body, then shutdown.
    fn with_app(&self, body: impl FnOnce(&Rc<EditorApplication>, u64, &Path)) {
        let app = self.launch();
        let id = app
            .geometry_authoring()
            .create(EditorGeometryPreset::Box)
            .expect("create box");
        body(&app, id, &self.root);
        app.shutdown();
    }
}

impl Drop for TopologyProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn document(app: &Rc<EditorApplication>, entity: u64) -> GeometryDocument {
    app.geometry_authoring()
        .document(entity)
        .expect("read geometry")
        .expect("referenced geometry")
}

fn face_count(mesh: &PolygonMesh) -> usize {
    mesh.faces.len()
}

fn control_faces(app: &Rc<EditorApplication>) -> Option<usize> {
    app.mesh_editing()
        .control_mesh()
        .map(|mesh| face_count(&mesh))
}

fn asset_path(app: &Rc<EditorApplication>, entity: u64) -> String {
    app.scene
        .referenced_asset(entity)
        .expect("referenced asset")
        .absolute_path
}

fn collider_triangle_count(app: &Rc<EditorApplication>, slot: i64) -> usize {
    app.scene
        .scene()
        .resource::<MeshColliderGeometryResource>()
        .and_then(|resource| {
            resource
                .geometry_by_resource_id
                .get(&format!("meshIndex:{slot}"))
                .map(|geometry| geometry.triangle_count())
        })
        .unwrap_or(0)
}

#[test]
fn component_modes_delete_the_matching_structure_and_keep_the_object() {
    for mode in [
        EditorMeshSelectionMode::Vertex,
        EditorMeshSelectionMode::Edge,
        EditorMeshSelectionMode::Face,
    ] {
        let project = TopologyProject::new();
        project.with_app(|app, id, _| {
            let editing = app.mesh_editing();
            assert!(editing.set_mode(mode));
            editing.select(BTreeSet::from([0]), false, false);
            let expected = match mode {
                EditorMeshSelectionMode::Vertex => 3,
                EditorMeshSelectionMode::Edge => 4,
                _ => 5,
            };
            assert!(editing.delete_selection());
            assert_eq!(control_faces(app), Some(expected));
            assert!(editing.selection().is_empty());
            assert_eq!(app.store.selected_entity_id(), Some(id));
            assert!(app.scene.entity_summary(Some(id)).is_some());

            // The edited geometry reaches disk: reopening the file yields the
            // same face count the control mesh reports.
            let path = asset_path(app, id);
            let source =
                GeometryDocument::load(&path).expect("load edited geometry");
            assert_eq!(
                source
                    .source
                    .evaluate(GeometryLimits::default())
                    .expect("evaluate")
                    .faces
                    .len(),
                expected
            );

            app.undo();
            editing.synchronize();
            assert_eq!(control_faces(app), Some(6));
            app.redo();
            editing.synchronize();
            assert_eq!(control_faces(app), Some(expected));
        });
    }
}

#[test]
fn deleting_every_face_keeps_modifiers_collision_data_and_reopening() {
    let project = TopologyProject::new();
    project.with_app(|app, id, root| {
        let editing = app.mesh_editing();
        assert!(editing.set_mode(EditorMeshSelectionMode::Face));
        let authoring = app.geometry_authoring();
        assert!(authoring.add_modifier(GeometryModifier::Subdivision { levels: 1 }, id));
        assert!(authoring.add_modifier(
            GeometryModifier::Array {
                count: 2,
                offset: Float3::new(2.0, 0.0, 0.0),
            },
            id
        ));
        let original = document(app, id);
        let slot = app
            .scene
            .referenced_asset(id)
            .expect("referenced asset")
            .mesh_index;
        let resource_id = format!("meshIndex:{slot}");

        editing.select_all();
        assert!(editing.delete_selection());
        assert!(editing.is_editing());
        assert!(
            editing
                .control_mesh()
                .expect("control mesh")
                .positions
                .is_empty()
        );

        let camera = app.scene.current_render_camera();
        let projection = EditorViewportProjection::new(
            camera,
            ViewportScreenFrame::new(0.0, 0.0, 400.0, 400.0),
        )
        .expect("projection");
        let picker = editing.picker().expect("picker");
        assert!(
            picker
                .pick(
                    100.0,
                    100.0,
                    EditorMeshSelectionMode::Face,
                    &projection,
                    false,
                    8.0,
                )
                .is_none()
        );

        assert_eq!(document(app, id).modifiers, original.modifiers);
        assert_eq!(collider_triangle_count(app, slot), 0);
        let bounds = app
            .scene
            .scene()
            .resource::<MeshColliderBoundsResource>()
            .and_then(|resource| resource.bounds_by_resource_id.get(&resource_id).cloned())
            .expect("collider bounds");
        assert_eq!(bounds.min, Float3::ZERO);
        assert_eq!(bounds.max, Float3::ZERO);

        assert!(app.save_scene_manifest().is_some());
        {
            let restored = EditorApplication::with_options(
                root.to_string_lossy().into_owned(),
                EditorApplicationOptions {
                    seed_preview_scene: false,
                    ..EditorApplicationOptions::default()
                },
            )
            .expect("reopen project");
            assert!(restored.open_scene_manifest().is_some());
            assert!(restored.scene.entity_summary(Some(id)).is_some());
            let reopened = document(&restored, id);
            assert!(
                reopened
                    .source
                    .evaluate(GeometryLimits::default())
                    .expect("evaluate")
                    .faces
                    .is_empty()
            );
            restored.shutdown();
        }

        app.undo();
        editing.synchronize();
        assert_eq!(document(app, id), original);
        assert!(collider_triangle_count(app, slot) > 0);
        app.redo();
        editing.synchronize();
        assert!(
            editing
                .control_mesh()
                .expect("control mesh")
                .faces
                .is_empty()
        );
        assert_eq!(collider_triangle_count(app, slot), 0);
    });
}

#[test]
fn dissolve_joins_triangulated_faces_and_shares_history() {
    let project = TopologyProject::new();
    project.with_app(|app, id, _| {
        let authoring = app.geometry_authoring();
        assert!(authoring.edit(id, |document| {
            document.source = GeometrySource::Grid {
                size: Float2::new(2.0, 2.0),
                segments: Int2::new(1, 1),
            };
            Ok(())
        }));
        let editing = app.mesh_editing();
        assert!(editing.set_mode(EditorMeshSelectionMode::Face));
        let original = editing.control_mesh().expect("original mesh");

        editing.select_all();
        assert!(editing.triangulate_selection());
        assert!(editing.set_mode(EditorMeshSelectionMode::Edge));
        let mesh = editing.control_mesh().expect("control mesh");
        let edge_index = mesh
            .edges()
            .iter()
            .position(|edge| {
                mesh.faces
                    .iter()
                    .filter(|face| {
                        face.vertices.contains(&edge.a) && face.vertices.contains(&edge.b)
                    })
                    .count()
                    == 2
            })
            .expect("shared edge");
        editing.select(BTreeSet::from([edge_index]), false, false);
        assert!(editing.dissolve_selection());
        assert_eq!(editing.control_mesh(), Some(original.clone()));
        assert!(editing.selection().is_empty());

        app.undo();
        editing.synchronize();
        assert_eq!(control_faces(app), Some(2));
        app.redo();
        editing.synchronize();
        assert_eq!(editing.control_mesh(), Some(original));
    });
}

#[test]
fn failed_dissolve_keeps_the_file_and_transforms_block_topology_edits() {
    let project = TopologyProject::new();
    project.with_app(|app, id, _| {
        let editing = app.mesh_editing();
        assert!(editing.set_mode(EditorMeshSelectionMode::Edge));
        let authoring = app.geometry_authoring();
        assert!(authoring.edit(id, |document| {
            let mut mesh =
                GeometryPrimitives::grid(Float2::new(2.0, 1.0), (2, 1), GeometryLimits::default())
                    .expect("grid");
            mesh.faces[1].material_index = 1;
            document.materials.push(Default::default());
            document.source = GeometrySource::Polygon { mesh };
            Ok(())
        }));
        editing.synchronize();
        let mesh = editing.control_mesh().expect("control mesh");
        let index = mesh
            .edges()
            .iter()
            .position(|edge| edge.a == 1 && edge.b == 4)
            .expect("edge 1-4");
        editing.select(BTreeSet::from([index]), false, false);

        let url = asset_path(app, id);
        let data = fs::read(&url).expect("source bytes");
        assert!(!editing.dissolve_selection());
        assert_eq!(fs::read(&url).expect("source bytes"), data);
        assert!(editing.begin_transform());
        assert!(!editing.delete_selection() && !editing.dissolve_selection());
        assert!(editing.cancel_transform());

        app.undo();
        editing.synchronize();
        assert_eq!(control_faces(app), Some(6));
    });
}
