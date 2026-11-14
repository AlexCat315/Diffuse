//! `Editor/Sources/EditorCore/Geometry/EditorMeshSurfaceOverlay.swift`.

use std::collections::BTreeSet;

use diffuse_assets::geometry::polygon_mesh::PolygonMeshEdge;
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4};
use diffuse_scene::rendering::render_geometry_overlay::{
    RenderGeometryOverlay, RenderGeometryTriangle,
};

use super::editor_mesh_picker::EditorMeshPicker;

impl EditorMeshPicker<'_> {
    /// Surface wires share the faces' depth interpolation. Per-triangle
    /// masks hide the internal diagonals of ear-clipped polygons.
    pub fn surface_overlay(
        &self,
        viewport: Float2,
        xray: bool,
        mut fill: impl FnMut(usize) -> Float4,
        mut style: impl FnMut(PolygonMeshEdge) -> Option<(Float4, f32)>,
    ) -> RenderGeometryOverlay {
        let mut overlay = RenderGeometryOverlay::with_xray(viewport, xray);
        let boundaries: Vec<BTreeSet<_>> = self
            .mesh
            .faces
            .iter()
            .map(|face| {
                let vertices = face.vertices.iter().copied();
                vertices
                    .clone()
                    .zip(vertices.cycle().skip(1))
                    .map(|(a, b)| PolygonMeshEdge::new(a, b))
                    .collect()
            })
            .collect();
        self.for_each_triangle(|face, [a, b, c]| {
            let edges = [(b, c), (c, a), (a, b)];
            let [(edge_a, width_a), (edge_b, width_b), (edge_c, width_c)] = edges.map(|(a, b)| {
                let edge = PolygonMeshEdge::new(i64::from(a), i64::from(b));
                if boundaries[face].contains(&edge)
                    && let Some(styled) = style(edge)
                {
                    return styled;
                }
                (Float4::ZERO, 0.0)
            });
            overlay.triangles.push(RenderGeometryTriangle::with_edges(
                self.positions[a as usize],
                self.positions[b as usize],
                self.positions[c as usize],
                fill(face),
                Float3::new(width_a, width_b, width_c),
                edge_a,
                edge_b,
                edge_c,
            ));
        });
        overlay
    }
}
