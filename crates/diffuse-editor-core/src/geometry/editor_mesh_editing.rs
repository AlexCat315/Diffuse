//! `Editor/Sources/EditorCore/Geometry/EditorMeshEditing.swift`.

use std::cell::{Cell, RefCell};
use std::collections::BTreeSet;
use std::rc::Rc;

use cove_platform::KeyModifiers;
use cove_ui_compose::scene_core::Rect;
use diffuse_assets::asset_registry::ImportableAssetKind;
use diffuse_assets::geometry::geometry_document::GeometrySource;
use diffuse_assets::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonMesh, PolygonMeshEdge,
};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4x4, simd_cross, simd_length};

use crate::editing::editor_gizmo_controller::EditorGizmoController;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};
use crate::state::editor_store::EditorStore;

use super::editor_geometry_authoring::EditorGeometryAuthoring;
use super::editor_mesh_loop_cut::EditorLoopCutState;
use super::editor_mesh_picker::{EditorMeshPicker, EditorMeshSelectionMode};

struct CachedPicker {
    entity: u64,
    world: Float4x4,
    picker: Rc<EditorMeshPicker<'static>>,
}

/// Shared by the main-thread viewport, inspector and command handlers.
pub struct EditorMeshEditing {
    pub(super) authoring: Rc<EditorGeometryAuthoring>,
    pub(super) scene: EditorSceneAdapter,
    pub(super) store: Rc<EditorStore>,
    invalidate_display: Rc<dyn Fn()>,
    entity_id: Cell<Option<u64>>,
    mode: Cell<EditorMeshSelectionMode>,
    pub(super) selection: RefCell<BTreeSet<usize>>,
    xray: Cell<bool>,
    shows_evaluated_wireframe: Cell<bool>,
    pub extrusion_distance: Cell<f32>,
    pub extrusion_direction: Cell<EditorMeshExtrusionDirection>,
    pub pointer: RefCell<EditorMeshPointerSession>,
    topology: RefCell<Vec<Vec<i64>>>,
    vertex_count: Cell<usize>,
    cached_picker: RefCell<Option<CachedPicker>>,
    transform_vertices: RefCell<Option<BTreeSet<i64>>>,
    pub(super) inset_faces: RefCell<Option<BTreeSet<i64>>>,
    pub(super) loop_cut: RefCell<EditorLoopCutState>,
    pub(super) inset_distance: Cell<f32>,
    pub(super) inset_preview_valid: Cell<bool>,
}

impl EditorMeshEditing {
    pub fn new(
        authoring: Rc<EditorGeometryAuthoring>,
        scene: EditorSceneAdapter,
        store: Rc<EditorStore>,
        invalidate_display: Rc<dyn Fn()>,
    ) -> Rc<Self> {
        let editing = Rc::new(Self {
            authoring,
            scene,
            store,
            invalidate_display,
            entity_id: Cell::new(None),
            mode: Cell::new(EditorMeshSelectionMode::Object),
            selection: RefCell::default(),
            xray: Cell::new(false),
            shows_evaluated_wireframe: Cell::new(true),
            extrusion_distance: Cell::new(0.25),
            extrusion_direction: Cell::new(EditorMeshExtrusionDirection::Normal),
            pointer: RefCell::default(),
            topology: RefCell::default(),
            vertex_count: Cell::new(0),
            cached_picker: RefCell::default(),
            transform_vertices: RefCell::default(),
            inset_faces: RefCell::default(),
            loop_cut: RefCell::default(),
            inset_distance: Cell::new(0.1),
            inset_preview_valid: Cell::new(false),
        });
        let weak = Rc::downgrade(&editing);
        let mut provider = editing.scene.additional_inspector_sections.borrow_mut();
        let previous = provider.take();
        *provider = Some(Rc::new(move |entity| {
            let mut sections = previous
                .as_ref()
                .map_or_else(Vec::new, |provider| provider(entity));
            if let Some(editing) = weak.upgrade() {
                sections.extend(editing.inspector_sections(entity));
            }
            sections
        }));
        drop(provider);
        editing
    }

    pub fn entity_id(&self) -> Option<u64> {
        self.entity_id.get()
    }
    pub fn mode(&self) -> EditorMeshSelectionMode {
        self.mode.get()
    }
    pub fn selection(&self) -> BTreeSet<usize> {
        self.selection.borrow().clone()
    }
    pub fn xray(&self) -> bool {
        self.xray.get()
    }
    pub fn shows_evaluated_wireframe(&self) -> bool {
        self.shows_evaluated_wireframe.get()
    }
    pub fn is_editing(&self) -> bool {
        self.entity_id().is_some() && self.mode() != EditorMeshSelectionMode::Object
    }
    pub fn is_transforming(&self) -> bool {
        self.transform_vertices.borrow().is_some()
    }
    pub fn has_topology_preview(&self) -> bool {
        self.is_insetting() || self.is_loop_cutting()
    }
    pub fn has_interactive_edit(&self) -> bool {
        self.is_transforming() || self.has_topology_preview()
    }

    fn editable_selection(&self) -> Option<u64> {
        let id = self.store.selected_entity_id()?;
        (self.store.playback_state() == PlaybackState::Stopped
            && self.scene.is_authoring_enabled()
            && !self.scene.is_entity_locked(id)
            && self
                .scene
                .referenced_asset(id)
                .is_some_and(|asset| asset.kind == ImportableAssetKind::Dmesh))
        .then_some(id)
    }

    pub fn can_enter(&self) -> bool {
        self.editable_selection().is_some()
    }

    pub fn set_mode(&self, mode: EditorMeshSelectionMode) -> bool {
        if mode == EditorMeshSelectionMode::Object {
            self.leave();
            return true;
        }
        let Some(id) = self.editable_selection() else {
            return false;
        };
        if self.entity_id() == Some(id) && self.mode() == mode {
            return true;
        }
        self.cancel_interactive_edit();
        if (self.entity_id() != Some(id) || !self.is_editing())
            && !self.authoring.edit(id, |document| {
                if !matches!(document.source, GeometrySource::Polygon { .. }) {
                    document.source = GeometrySource::Polygon {
                        mesh: document.source.evaluate(GeometryLimits::default())?,
                    };
                }
                Ok(())
            })
        {
            return false;
        }
        self.entity_id.set(Some(id));
        self.mode.set(mode);
        self.selection.borrow_mut().clear();
        if let Some(mesh) = self.control_mesh() {
            self.remember_topology(&mesh);
        }
        self.refresh();
        true
    }

    pub fn synchronize(&self) {
        if !self.is_editing() {
            return;
        }
        let mesh = (self.editable_selection() == self.entity_id())
            .then(|| self.control_mesh())
            .flatten();
        let Some(mesh) = mesh else {
            self.leave();
            return;
        };
        let topology_changed = self.vertex_count.get() != mesh.positions.len()
            || !self
                .topology
                .borrow()
                .iter()
                .eq(mesh.faces.iter().map(|face| &face.vertices));
        if !self.has_topology_preview() && topology_changed {
            self.cancel_transform();
            self.selection.borrow_mut().clear();
            if let Some(mesh) = self.control_mesh() {
                self.remember_topology(&mesh);
            }
            self.refresh();
        }
    }

    pub fn leave(&self) {
        self.entity_id.set(None);
        self.mode.set(EditorMeshSelectionMode::Object);
        self.cancel_interactive_edit();
        self.pointer.borrow_mut().clear();
        self.selection.borrow_mut().clear();
        self.topology.borrow_mut().clear();
        self.vertex_count.set(0);
        self.cached_picker.borrow_mut().take();
        self.refresh();
    }

    pub fn set_xray(&self, enabled: bool) {
        self.xray.set(enabled);
        self.refresh();
    }
    pub fn set_evaluated_wireframe(&self, enabled: bool) {
        self.shows_evaluated_wireframe.set(enabled);
        self.refresh();
    }

    pub fn has_modifiers(&self) -> bool {
        self.entity_id()
            .and_then(|id| self.authoring.document(id).ok().flatten())
            .is_some_and(|doc| doc.modifiers.iter().any(|entry| entry.enabled))
    }

    pub fn apply_modifiers(&self) -> bool {
        self.synchronize();
        let Some(id) = self.entity_id().filter(|_| !self.has_interactive_edit()) else {
            return false;
        };
        let Some(last) = self
            .authoring
            .document(id)
            .ok()
            .flatten()
            .and_then(|mut doc| doc.modifiers.pop())
        else {
            return false;
        };
        let success = self.authoring.apply_modifier(&last.id, id);
        if success {
            self.synchronize();
            self.refresh();
        }
        success
    }

    pub fn subdivide_selection(&self) -> bool {
        self.edit_faces(|mesh, faces| mesh.subdivide_faces(faces, GeometryLimits::default()))
    }

    pub fn triangulate_selection(&self) -> bool {
        self.edit_faces(|mesh, faces| mesh.triangulate_faces(faces, GeometryLimits::default()))
    }

    pub fn delete_selection(&self) -> bool {
        self.edit_components(|mesh, mode, indices| {
            let empty = BTreeSet::new();
            let (vertices, edges, faces) = match mode {
                EditorMeshSelectionMode::Vertex => (indices, BTreeSet::new(), &empty),
                EditorMeshSelectionMode::Edge => (&empty, selected_edges(mesh, indices)?, &empty),
                EditorMeshSelectionMode::Face => (&empty, BTreeSet::new(), indices),
                EditorMeshSelectionMode::Object => return Ok(BTreeSet::new()),
            };
            mesh.delete(vertices, &edges, faces, GeometryLimits::default())?;
            Ok(BTreeSet::new())
        })
    }

    pub fn dissolve_selection(&self) -> bool {
        self.mode() == EditorMeshSelectionMode::Edge
            && self.edit_components(|mesh, _, indices| {
                mesh.dissolve(&selected_edges(mesh, indices)?, GeometryLimits::default())?;
                Ok(BTreeSet::new())
            })
    }

    fn edit_faces(
        &self,
        update: impl FnOnce(&mut PolygonMesh, &BTreeSet<i64>) -> Result<BTreeSet<i64>, GeometryError>,
    ) -> bool {
        self.mode() == EditorMeshSelectionMode::Face
            && self.edit_components(|mesh, _, selection| update(mesh, selection))
    }

    fn edit_components(
        &self,
        update: impl FnOnce(
            &mut PolygonMesh,
            EditorMeshSelectionMode,
            &BTreeSet<i64>,
        ) -> Result<BTreeSet<i64>, GeometryError>,
    ) -> bool {
        self.synchronize();
        let Some(id) = self.entity_id().filter(|_| !self.has_interactive_edit()) else {
            return false;
        };
        let selection = self.signed_selection();
        if selection.is_empty() {
            return false;
        }
        let mode = self.mode();
        let mut next = BTreeSet::new();
        let success = self.authoring.edit(id, |doc| {
            if let GeometrySource::Polygon { mesh } = &mut doc.source {
                next = update(mesh, mode, &selection)?;
            }
            Ok(())
        });
        if success && let Some(mesh) = self.control_mesh() {
            self.remember_topology(&mesh);
            self.selection
                .replace(next.into_iter().map(|index| index as usize).collect());
            self.refresh();
        }
        success
    }

    pub fn select(&self, indices: BTreeSet<usize>, extending: bool, toggling: bool) {
        self.synchronize();
        let Some(count) = self.selectable_count() else {
            return;
        };
        let valid: BTreeSet<_> = indices.into_iter().filter(|&index| index < count).collect();
        {
            let mut selection = self.selection.borrow_mut();
            if toggling {
                *selection = selection.symmetric_difference(&valid).copied().collect();
            } else if extending {
                selection.extend(valid);
            } else {
                *selection = valid;
            }
        }
        self.refresh();
    }

    pub fn select_all(&self) {
        self.synchronize();
        if let Some(count) = self.selectable_count() {
            self.selection.replace((0..count).collect());
            self.refresh();
        }
    }

    pub fn invert_selection(&self) {
        self.synchronize();
        if let Some(count) = self.selectable_count() {
            {
                let mut selection = self.selection.borrow_mut();
                *selection = (0..count)
                    .filter(|index| !selection.contains(index))
                    .collect();
            }
            self.refresh();
        }
    }

    fn selectable_count(&self) -> Option<usize> {
        if !self.is_editing() || self.has_interactive_edit() {
            return None;
        }
        let picker = self.picker()?;
        match self.mode() {
            EditorMeshSelectionMode::Object => None,
            EditorMeshSelectionMode::Vertex => Some(picker.positions.len()),
            EditorMeshSelectionMode::Edge => Some(picker.edges.len()),
            EditorMeshSelectionMode::Face => Some(picker.mesh.faces.len()),
        }
    }

    pub fn control_mesh(&self) -> Option<PolygonMesh> {
        match self.authoring.document(self.entity_id()?).ok()??.source {
            GeometrySource::Polygon { mesh } => Some(mesh),
            _ => None,
        }
    }

    pub fn picker(&self) -> Option<Rc<EditorMeshPicker<'static>>> {
        let entity = self.entity_id()?;
        let mesh = self.control_mesh()?;
        let world = self.scene.entity_world_matrix(entity)?;
        if let Some(cache) = &*self.cached_picker.borrow()
            && cache.entity == entity
            && cache.world == world
            && cache.picker.mesh == mesh
        {
            return Some(Rc::clone(&cache.picker));
        }
        let picker = self.authoring.make_picker(entity, mesh, world)?;
        self.cached_picker.replace(Some(CachedPicker {
            entity,
            world,
            picker: Rc::clone(&picker),
        }));
        Some(picker)
    }

    pub fn selected_vertices(&self) -> BTreeSet<i64> {
        let Some(picker) = self.picker() else {
            return BTreeSet::new();
        };
        let selection = self.selection.borrow();
        match self.mode() {
            EditorMeshSelectionMode::Object => BTreeSet::new(),
            EditorMeshSelectionMode::Vertex => selection
                .iter()
                .filter(|&&index| index < picker.positions.len())
                .map(|&index| index as i64)
                .collect(),
            EditorMeshSelectionMode::Edge => selection
                .iter()
                .filter_map(|&index| picker.edges.get(index))
                .flat_map(|edge| [edge.a, edge.b])
                .collect(),
            EditorMeshSelectionMode::Face => selection
                .iter()
                .filter_map(|&index| picker.mesh.faces.get(index))
                .flat_map(|face| face.vertices.iter().copied())
                .collect(),
        }
    }

    pub fn selection_center(&self) -> Option<Float3> {
        let mesh = self.control_mesh()?;
        let vertices = self.selected_vertices();
        let count = vertices.len() as f32;
        (!vertices.is_empty()).then(|| {
            vertices.iter().fold(Float3::ZERO, |sum, &index| {
                sum + mesh.positions[index as usize] / count
            })
        })
    }

    pub fn move_selection_center(&self, position: Float3) -> bool {
        self.synchronize();
        let Some(id) = self.entity_id().filter(|_| !self.has_interactive_edit()) else {
            return false;
        };
        let Some(center) = self.selection_center() else {
            return false;
        };
        let vertices = self.selected_vertices();
        self.authoring.edit(id, |doc| {
            if let GeometrySource::Polygon { mesh } = &mut doc.source {
                mesh.translate(&vertices, position - center, GeometryLimits::default())?;
            }
            Ok(())
        })
    }

    pub fn extrude_region(&self) -> bool {
        use EditorMeshExtrusionDirection::{Normal, X, Y, Z};
        self.synchronize();
        let Some(id) = self.entity_id().filter(|_| {
            !self.has_interactive_edit() && self.mode() == EditorMeshSelectionMode::Face
        }) else {
            return false;
        };
        let selection = self.signed_selection();
        let distance = self.extrusion_distance.get();
        if selection.is_empty() || !distance.is_finite() || distance == 0.0 {
            return false;
        }
        let direction = match self.extrusion_direction.get() {
            X => Float3::new(1.0, 0.0, 0.0),
            Y => Float3::new(0.0, 1.0, 0.0),
            Z => Float3::new(0.0, 0.0, 1.0),
            Normal => {
                let Some(mesh) = self.control_mesh() else {
                    return false;
                };
                let mut normal = Float3::ZERO;
                for face in selection
                    .iter()
                    .filter_map(|&index| mesh.faces.get(index as usize))
                {
                    let origin = mesh.positions[face.vertices[0] as usize];
                    for (a, b) in face
                        .vertices
                        .iter()
                        .zip(face.vertices.iter().cycle().skip(1))
                    {
                        normal += simd_cross(
                            mesh.positions[*a as usize] - origin,
                            mesh.positions[*b as usize] - origin,
                        );
                    }
                }
                let length = simd_length(normal);
                if !length.is_finite() || length <= 1e-8 {
                    self.store.dispatch(EditorAction::console_message(
                        "Choose an extrusion axis for a selection without a common normal",
                    ));
                    return false;
                }
                normal / length
            }
        };
        let success = self.authoring.edit(id, |doc| {
            if let GeometrySource::Polygon { mesh } = &mut doc.source {
                mesh.extrude_faces(&selection, direction * distance, GeometryLimits::default())?;
            }
            Ok(())
        });
        if success && let Some(mesh) = self.control_mesh() {
            self.remember_topology(&mesh);
            self.refresh();
        }
        success
    }

    pub fn begin_transform(&self) -> bool {
        self.synchronize();
        let Some(id) = self
            .entity_id()
            .filter(|_| self.is_editing() && !self.has_interactive_edit())
        else {
            return false;
        };
        let vertices = self.selected_vertices();
        if vertices.is_empty() || !self.authoring.begin_interactive_edit(id) {
            return false;
        }
        self.transform_vertices.replace(Some(vertices));
        true
    }

    pub fn preview_transform(&self, delta: Float4x4) -> bool {
        let Some(vertices) = self.transform_vertices.borrow().clone() else {
            return false;
        };
        self.authoring.preview_interactive_edit(|document| {
            if let GeometrySource::Polygon { mesh } = &mut document.source {
                mesh.transform(&vertices, delta, GeometryLimits::default())?;
            }
            Ok(())
        })
    }

    pub fn finish_transform(&self) -> bool {
        self.clear_transform() && self.authoring.commit_interactive_edit()
    }

    pub fn cancel_transform(&self) -> bool {
        if !self.clear_transform() {
            return false;
        }
        self.authoring.cancel_interactive_edit();
        true
    }

    fn clear_transform(&self) -> bool {
        if self.transform_vertices.borrow_mut().take().is_none() {
            return false;
        }
        EditorGizmoController::shared().clear_drag();
        self.pointer.borrow_mut().clear();
        true
    }

    pub(super) fn signed_selection(&self) -> BTreeSet<i64> {
        self.selection
            .borrow()
            .iter()
            .map(|&index| index as i64)
            .collect()
    }

    pub(super) fn remember_topology(&self, mesh: &PolygonMesh) {
        self.topology.replace(
            mesh.faces
                .iter()
                .map(|face| face.vertices.clone())
                .collect(),
        );
        self.vertex_count.set(mesh.positions.len());
    }

    pub(super) fn refresh(&self) {
        self.store.geometry_changed();
        (self.invalidate_display)();
    }

    pub(super) fn report_error(&self, message: &str, detail: Option<String>) {
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: message.into(),
            severity: EditorConsoleSeverity::Error,
            detail,
            target: None,
            next_step: None,
        });
    }
}

fn selected_edges(
    mesh: &PolygonMesh,
    indices: &BTreeSet<i64>,
) -> Result<BTreeSet<PolygonMeshEdge>, GeometryError> {
    let edges = mesh.edges();
    indices
        .iter()
        .map(|&index| {
            edges
                .get(index as usize)
                .copied()
                .ok_or_else(|| GeometryError::invalid_parameter("edge selection"))
        })
        .collect()
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EditorMeshExtrusionDirection {
    #[default]
    Normal,
    X,
    Y,
    Z,
}

impl EditorMeshExtrusionDirection {
    pub const ALL: [Self; 4] = [Self::Normal, Self::X, Self::Y, Self::Z];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::X => "x",
            Self::Y => "y",
            Self::Z => "z",
        }
    }
}

#[derive(Default)]
pub struct EditorMeshPointerSession {
    pub start: Option<Float2>,
    pub current: Option<Float2>,
    pub modifiers: KeyModifiers,
    pub marquee: Option<Rect>,
    pub gizmo_start: Option<Float4x4>,
    pub object_world: Option<Float4x4>,
}

impl EditorMeshPointerSession {
    pub fn clear(&mut self) {
        *self = Self::default();
    }
}
