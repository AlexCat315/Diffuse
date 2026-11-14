//! `Editor/Sources/EditorCore/Geometry/EditorMeshInset.swift`.

use diffuse_assets::geometry::geometry_document::GeometrySource;
use diffuse_assets::geometry::polygon_mesh::{GeometryError, GeometryLimits};

use super::editor_mesh_editing::EditorMeshEditing;
use super::editor_mesh_picker::EditorMeshSelectionMode;

impl EditorMeshEditing {
    pub fn is_insetting(&self) -> bool { self.inset_faces.borrow().is_some() }
    pub fn inset_distance(&self) -> f32 { self.inset_distance.get() }
    pub fn is_inset_preview_valid(&self) -> bool { self.inset_preview_valid.get() }

    pub fn begin_inset(&self) -> bool {
        self.synchronize();
        if self.has_interactive_edit() || self.pointer.borrow().start.is_some()
            || self.mode() != EditorMeshSelectionMode::Face
        {
            return false;
        }
        let faces = self.signed_selection();
        let Some(id) = self.entity_id().filter(|_| !faces.is_empty()) else { return false };
        let Some(mesh) = self.control_mesh() else { return false };
        let width = match mesh.suggested_inset_distance(&faces, 0.1, GeometryLimits::default()) {
            Ok(width) => width,
            Err(error) => {
                self.report_error("Inset requires convex planar faces with affine UVs", Some(error.to_string()));
                return false;
            }
        };
        if !self.authoring.begin_interactive_edit(id) { return false; }
        self.inset_faces.replace(Some(faces));
        if self.preview_inset(width) { return true; }
        self.cancel_inset();
        false
    }

    pub fn preview_inset(&self, distance: f32) -> bool {
        let Some(faces) = self.inset_faces.borrow().clone() else { return false };
        self.inset_distance.set(distance);
        let valid = self.authoring.preview_interactive_edit(|document| {
            let GeometrySource::Polygon { mesh } = &mut document.source else {
                return Err(GeometryError::invalid_parameter("inset source"));
            };
            mesh.inset(&faces, distance, GeometryLimits::default())
        });
        self.inset_preview_valid.set(valid);
        self.refresh();
        valid
    }

    pub fn commit_inset(&self) -> bool {
        if !self.is_insetting() || !self.is_inset_preview_valid() { return false; }
        self.clear_inset();
        let success = self.authoring.commit_interactive_edit();
        if success && let Some(mesh) = self.control_mesh() {
            self.remember_topology(&mesh);
        } else {
            self.synchronize();
        }
        self.refresh();
        success
    }

    pub fn cancel_inset(&self) -> bool {
        if !self.is_insetting() { return false; }
        self.clear_inset();
        self.authoring.cancel_interactive_edit();
        self.synchronize();
        self.refresh();
        true
    }

    fn clear_inset(&self) {
        self.inset_faces.borrow_mut().take();
        self.inset_preview_valid.set(false);
    }

    pub fn cancel_interactive_edit(&self) -> bool {
        if self.is_loop_cutting() { self.cancel_loop_cut() }
        else if self.is_insetting() { self.cancel_inset() }
        else { self.cancel_transform() }
    }

    pub fn commit_interactive_edit(&self) -> bool {
        if self.is_loop_cutting() { self.commit_loop_cut() }
        else if self.is_insetting() { self.commit_inset() }
        else { self.finish_transform() }
    }
}
