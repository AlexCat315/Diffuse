//! `Editor/Sources/EditorCore/Geometry/EditorMeshRendering.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use diffuse_assets::geometry::polygon_mesh::PolygonMeshEdge;
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, simd_cross, simd_dot};
use diffuse_render::RenderDrawableSize;
use diffuse_scene::rendering::render_geometry_overlay::RenderGeometryOverlay;
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

use crate::application::editor_application::EditorApplication;
use crate::assets::asset_catalog::EditorViewportDropTarget;
use crate::state::editor_state::EditorViewportShadingMode;
use crate::state::workspace::editor_workbench_state::EditorViewportMode;

use super::editor_mesh_editing::EditorMeshEditing;
use super::editor_mesh_picker::{EditorMeshPicker, EditorMeshSelectionMode};

impl EditorMeshEditing {
    pub fn render_overlay(&self, viewport: Float2) -> Option<RenderGeometryOverlay> {
        if !self.is_editing() {
            return None;
        }
        let picker = self.picker()?;
        let active = Float4::new(1.0, 0.58, 0.12, 1.0);
        let inactive = Float4::new(0.65, 0.72, 0.8, 0.85);
        let mode = self.mode();
        let xray = self.xray();
        let selection = self.selection();
        let vertices = self.selected_vertices();
        let mut edges = BTreeSet::new();
        match mode {
            EditorMeshSelectionMode::Face => {
                for face in selection
                    .iter()
                    .filter_map(|&index| picker.mesh.faces.get(index))
                {
                    edges.extend(
                        face.vertices
                            .iter()
                            .zip(face.vertices.iter().cycle().skip(1))
                            .map(|(&a, &b)| PolygonMeshEdge::new(a, b)),
                    );
                }
            }
            EditorMeshSelectionMode::Edge => edges.extend(
                selection
                    .iter()
                    .filter_map(|&index| picker.edges.get(index))
                    .copied(),
            ),
            _ => {}
        }
        Some(picker.surface_overlay(
            viewport,
            xray,
            |face| {
                if mode == EditorMeshSelectionMode::Face && selection.contains(&face) {
                    Float4::new(1.0, 0.48, 0.08, if xray { 0.16 } else { 0.27 })
                } else {
                    Float4::ZERO
                }
            },
            |edge| {
                let selected = if mode == EditorMeshSelectionMode::Vertex {
                    vertices.contains(&edge.a) && vertices.contains(&edge.b)
                } else {
                    edges.contains(&edge)
                };
                Some(if selected {
                    (active, 2.0)
                } else {
                    (inactive, 1.0)
                })
            },
        ))
    }

    pub fn geometry_overlays(&self, viewport: Float2) -> Vec<RenderGeometryOverlay> {
        if self.store.viewport_mode() != EditorViewportMode::Scene {
            return Vec::new();
        }
        self.synchronize();
        if !viewport.x.is_finite()
            || !viewport.y.is_finite()
            || viewport.x <= 0.0
            || viewport.y <= 0.0
        {
            return Vec::new();
        }
        if let Some(overlay) = self.render_overlay(viewport) {
            let mut result = Vec::new();
            if self.shows_evaluated_wireframe()
                && self.has_modifiers()
                && let Some(picker) = self
                    .entity_id()
                    .and_then(|id| self.authoring.viewport_picker(id))
            {
                result.push(picker.surface_overlay(
                    viewport,
                    false,
                    |_| Float4::ZERO,
                    |_| Some((Float4::new(0.35, 0.7, 0.78, 0.55), 1.0)),
                ));
            }
            result.push(overlay);
            return result;
        }
        if self.store.viewport_shading_mode() == EditorViewportShadingMode::Wireframe {
            return Vec::new();
        }
        let mut selection = self.store.selected_entity_ids();
        if selection.is_empty() {
            selection.extend(self.store.selected_entity_id());
        }
        let mut result = RenderGeometryOverlay::new(viewport);
        let camera = self.scene.current_render_camera();
        for (entity, _, _) in self.scene.viewport_world_bounds() {
            if selection.contains(&entity)
                && let Some(picker) = self.authoring.viewport_picker(entity)
            {
                let contour = silhouette(&picker, &camera);
                result.triangles.extend(
                    picker
                        .surface_overlay(
                            viewport,
                            false,
                            |_| Float4::ZERO,
                            |edge| {
                                contour
                                    .contains(&edge)
                                    .then_some((Float4::new(1.0, 0.65, 0.18, 1.0), 2.0))
                            },
                        )
                        .triangles,
                );
            }
        }
        if result.is_empty() {
            Vec::new()
        } else {
            vec![result]
        }
    }
}

impl EditorApplication {
    pub fn make_geometry_overlays(
        self: &Rc<Self>,
        drawable_size: RenderDrawableSize,
    ) -> Vec<RenderGeometryOverlay> {
        let viewport = EditorViewportDropTarget::frame().map_or(
            Float2::new(drawable_size.width as f32, drawable_size.height as f32),
            |frame| Float2::new(frame.width, frame.height),
        );
        self.mesh_editing().geometry_overlays(viewport)
    }
}

fn silhouette(picker: &EditorMeshPicker<'_>, camera: &RenderCamera) -> BTreeSet<PolygonMeshEdge> {
    let mut uses = BTreeMap::<_, (usize, u8)>::new();
    for face in &picker.mesh.faces {
        let origin = picker.positions[face.vertices[0] as usize];
        let vertices = || {
            face.vertices
                .iter()
                .zip(face.vertices.iter().cycle().skip(1))
        };
        let normal = vertices().fold(Float3::ZERO, |sum, (&a, &b)| {
            sum + simd_cross(
                picker.positions[a as usize] - origin,
                picker.positions[b as usize] - origin,
            )
        });
        let view = if camera.projection == RenderCameraProjection::Orthographic {
            camera.eye - camera.target
        } else {
            camera.eye - origin
        };
        let side = if simd_dot(normal, view) >= 0.0 { 1 } else { 2 };
        for (&a, &b) in vertices() {
            let (count, sides) = uses.entry(PolygonMeshEdge::new(a, b)).or_default();
            *count += 1;
            *sides |= side;
        }
    }
    uses.into_iter()
        .filter_map(|(edge, (count, sides))| (count == 1 || sides == 3).then_some(edge))
        .collect()
}
