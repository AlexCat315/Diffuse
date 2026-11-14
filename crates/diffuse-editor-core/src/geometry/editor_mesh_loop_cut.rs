//! `Editor/Sources/EditorCore/Geometry/EditorMeshLoopCut.swift`.

use std::collections::BTreeSet;

use diffuse_assets::geometry::geometry_document::GeometrySource;
use diffuse_assets::geometry::polygon_mesh::{GeometryError, GeometryLimits, PolygonMeshEdge};

use super::editor_mesh_editing::EditorMeshEditing;
use super::editor_mesh_picker::EditorMeshSelectionMode;

pub(super) struct EditorLoopCutState {
    seed: Option<PolygonMeshEdge>,
    original_selection: BTreeSet<usize>,
    count: i64,
    slide: f32,
    valid: bool,
}

impl Default for EditorLoopCutState {
    fn default() -> Self {
        Self { seed: None, original_selection: BTreeSet::new(), count: 1, slide: 0.0, valid: false }
    }
}

impl EditorMeshEditing {
    pub fn is_loop_cutting(&self) -> bool { self.loop_cut.borrow().seed.is_some() }
    pub fn loop_cut_count(&self) -> i64 { self.loop_cut.borrow().count }
    pub fn loop_cut_slide(&self) -> f32 { self.loop_cut.borrow().slide }
    pub fn is_loop_cut_preview_valid(&self) -> bool { self.loop_cut.borrow().valid }

    pub fn begin_loop_cut(&self) -> bool {
        self.synchronize();
        if self.has_interactive_edit() || self.pointer.borrow().start.is_some()
            || self.mode() != EditorMeshSelectionMode::Edge
        {
            return false;
        }
        let original_selection = self.selection();
        let Some(id) = self.entity_id().filter(|_| original_selection.len() == 1) else { return false };
        let Some(seed) = self.picker().and_then(|picker| picker.edges.get(*original_selection.first()?).copied()) else {
            return false;
        };
        if !self.authoring.begin_interactive_edit(id) { return false; }
        self.loop_cut.replace(EditorLoopCutState {
            seed: Some(seed), original_selection, ..EditorLoopCutState::default()
        });
        if self.preview_loop_cut(1, 0.0) { return true; }
        self.cancel_loop_cut();
        self.report_error("Loop cut requires a consistent strip of convex planar quads with affine UVs", None);
        false
    }

    pub fn preview_loop_cut(&self, cuts: i64, slide: f32) -> bool {
        let seed = {
            let mut state = self.loop_cut.borrow_mut();
            let Some(seed) = state.seed else { return false };
            state.count = cuts;
            state.slide = slide;
            seed
        };
        let mut edges = BTreeSet::new();
        let valid = self.authoring.preview_interactive_edit(|document| {
            let GeometrySource::Polygon { mesh } = &mut document.source else {
                return Err(GeometryError::invalid_parameter("loop cut source"));
            };
            edges = mesh.loop_cut(seed, cuts, slide, GeometryLimits::default())?;
            Ok(())
        });
        self.loop_cut.borrow_mut().valid = valid;
        if valid && let Some(mesh) = self.control_mesh() {
            self.selection.replace(mesh.edges().iter().enumerate()
                .filter_map(|(index, edge)| edges.contains(edge).then_some(index)).collect());
        }
        self.refresh();
        valid
    }

    pub fn commit_loop_cut(&self) -> bool {
        if !self.is_loop_cutting() || !self.is_loop_cut_preview_valid() { return false; }
        let original = self.clear_loop_cut();
        let success = self.authoring.commit_interactive_edit();
        if success && let Some(mesh) = self.control_mesh() {
            self.remember_topology(&mesh);
        } else {
            self.selection.replace(original);
            self.synchronize();
        }
        self.refresh();
        success
    }

    pub fn cancel_loop_cut(&self) -> bool {
        if !self.is_loop_cutting() { return false; }
        let original = self.clear_loop_cut();
        self.authoring.cancel_interactive_edit();
        self.selection.replace(original);
        self.synchronize();
        self.refresh();
        true
    }

    fn clear_loop_cut(&self) -> BTreeSet<usize> {
        let mut state = self.loop_cut.borrow_mut();
        state.seed = None;
        state.valid = false;
        std::mem::take(&mut state.original_selection)
    }
}
