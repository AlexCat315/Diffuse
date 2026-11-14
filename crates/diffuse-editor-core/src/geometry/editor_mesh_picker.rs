//! `Editor/Sources/EditorCore/Geometry/EditorMeshPicker.swift`.

use std::collections::BTreeSet;

use cove_ui_compose::scene_core::Rect;
use diffuse_assets::geometry::polygon_mesh::{GeometryError, PolygonMesh, PolygonMeshEdge};
use diffuse_math::simd::simd_compat::{
    Float2, Float3, Float4, Float4x4, simd_cross, simd_dot, simd_dot2, simd_length,
    simd_length_squared2, simd_max, simd_min,
};
use diffuse_render::registries::mesh_picking_registry::MeshPickingSurface;

use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorMeshSelectionMode {
    Object,
    Vertex,
    Edge,
    Face,
}

impl EditorMeshSelectionMode {
    pub const ALL: [Self; 4] = [Self::Object, Self::Vertex, Self::Edge, Self::Face];

    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Object => "object",
            Self::Vertex => "vertex",
            Self::Edge => "edge",
            Self::Face => "face",
        }
    }

    pub const fn title(self) -> &'static str {
        match self {
            Self::Object => "Object",
            Self::Vertex => "Vertex",
            Self::Edge => "Edge",
            Self::Face => "Face",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EditorMeshElementHit {
    pub index: usize,
    pub world_position: Float3,
    pub distance: f32,
}

pub type OccluderDistance<'a> = dyn Fn(Float3, Float3) -> Option<f32> + 'a;

/// Picks control vertices, edges and faces using the viewport's camera.
pub struct EditorMeshPicker<'a> {
    pub mesh: PolygonMesh,
    pub positions: Vec<Float3>,
    pub edges: Vec<PolygonMeshEdge>,
    triangles: Vec<u32>,
    face_for_triangle: Vec<usize>,
    surface: MeshPickingSurface,
    tolerance: f32,
    occluder_distance: Option<Box<OccluderDistance<'a>>>,
}

impl<'a> EditorMeshPicker<'a> {
    pub fn new(
        mesh: PolygonMesh,
        world_matrix: Float4x4,
        occluder_distance: Option<Box<OccluderDistance<'a>>>,
    ) -> Result<Self, GeometryError> {
        let topology = mesh.topology_slice()?;
        let positions: Vec<_> = mesh
            .positions
            .iter()
            .map(|p| (world_matrix * homogeneous(*p)).xyz())
            .collect();
        if positions
            .iter()
            .any(|p| !(p.x.is_finite() && p.y.is_finite() && p.z.is_finite()))
        {
            return Err(GeometryError::invalid_parameter("mesh world transform"));
        }
        let edges = mesh.edges();
        let triangles = topology.triangle_indices;
        let face_for_triangle = mesh
            .faces
            .iter()
            .enumerate()
            .flat_map(|(index, face)| std::iter::repeat_n(index, face.vertices.len() - 2))
            .collect();
        let surface = MeshPickingSurface::new(&positions, &triangles);
        let tolerance = if positions.is_empty() {
            0.00001
        } else {
            let lo = positions.iter().copied().fold(Float3::INFINITY, simd_min);
            let hi = positions
                .iter()
                .copied()
                .fold(Float3::NEG_INFINITY, simd_max);
            (simd_length(hi - lo) * 0.0001).max(0.00001)
        };
        Ok(Self {
            mesh,
            positions,
            edges,
            triangles,
            face_for_triangle,
            surface,
            tolerance,
            occluder_distance,
        })
    }

    /// Visits the same ear-clipped topology used by the geometry pipeline.
    pub fn for_each_triangle(&self, mut visit: impl FnMut(usize, [u32; 3])) {
        for (&face, &indices) in self
            .face_for_triangle
            .iter()
            .zip(self.triangles.as_chunks::<3>().0)
        {
            visit(face, indices);
        }
    }

    pub fn is_visible(
        &self,
        point: Float3,
        projection: &EditorViewportProjection,
        xray: bool,
    ) -> bool {
        let Some((x, y)) = projection.project_default(point) else {
            return false;
        };
        if !projection.frame.contains(x, y) {
            return false;
        }
        if xray {
            return true;
        }
        let (origin, direction) = projection.cursor_ray(x, y);
        let depth = simd_dot(point - origin, direction);
        if depth < 0.0 || self.is_occluded(origin, direction, depth) {
            return false;
        }
        self.surface
            .hit_distance(origin, direction, depth + self.tolerance)
            .is_none_or(|hit| hit >= depth - self.tolerance.max(depth * 0.00001))
    }

    pub fn pick(
        &self,
        x: f32,
        y: f32,
        mode: EditorMeshSelectionMode,
        projection: &EditorViewportProjection,
        xray: bool,
        radius: f32,
    ) -> Option<EditorMeshElementHit> {
        if !projection.frame.contains(x, y) || !radius.is_finite() || radius < 0.0 {
            return None;
        }
        let (origin, direction) = projection.cursor_ray(x, y);
        if mode == EditorMeshSelectionMode::Face {
            let hit = self.face_hit(origin, direction)?;
            return (xray || !self.is_occluded(origin, direction, hit.distance)).then_some(hit);
        }
        let cursor = Float2::new(x, y);
        let mut best: Option<EditorMeshElementHit> = None;
        let mut best_distance = radius * radius;
        let mut consider = |point, index, screen| {
            let distance = simd_length_squared2(screen - cursor);
            let depth = simd_dot(point - origin, direction);
            if distance <= best_distance
                && depth >= 0.0
                && self.is_visible(point, projection, xray)
                && !best.is_some_and(|hit| {
                    (distance - best_distance).abs() < 0.25 && hit.distance < depth
                })
            {
                best_distance = distance;
                best = Some(EditorMeshElementHit {
                    index,
                    world_position: point,
                    distance: depth,
                });
            }
        };
        match mode {
            EditorMeshSelectionMode::Vertex => {
                for (index, &point) in self.positions.iter().enumerate() {
                    if let Some((x, y)) = projection.project_default(point) {
                        consider(point, index, Float2::new(x, y));
                    }
                }
            }
            EditorMeshSelectionMode::Edge => {
                for (index, edge) in self.edges.iter().enumerate() {
                    let a = self.positions[edge.a as usize];
                    let b = self.positions[edge.b as usize];
                    let (Some((ax, ay)), Some((bx, by))) =
                        (projection.project_default(a), projection.project_default(b))
                    else {
                        continue;
                    };
                    let start = Float2::new(ax, ay);
                    let delta = Float2::new(bx, by) - start;
                    let length = simd_length_squared2(delta);
                    let t = if length > 1e-8 {
                        (simd_dot2(cursor - start, delta) / length).clamp(0.0, 1.0)
                    } else {
                        0.0
                    };
                    let wa = (projection.view_projection_matrix * homogeneous(a)).w;
                    let wb = (projection.view_projection_matrix * homogeneous(b)).w;
                    let a_weight = (1.0 - t) / wa;
                    let b_weight = t / wb;
                    let denominator = a_weight + b_weight;
                    if denominator.abs() > 1e-12 {
                        let point = (a * a_weight + b * b_weight) / denominator;
                        consider(point, index, start + delta * t);
                    }
                }
            }
            EditorMeshSelectionMode::Face | EditorMeshSelectionMode::Object => return None,
        }
        best
    }

    pub fn pick_in_rect(
        &self,
        rect: Rect,
        mode: EditorMeshSelectionMode,
        projection: &EditorViewportProjection,
        xray: bool,
    ) -> BTreeSet<usize> {
        let centers = match mode {
            EditorMeshSelectionMode::Object => return BTreeSet::new(),
            EditorMeshSelectionMode::Vertex => self.positions.clone(),
            EditorMeshSelectionMode::Edge => self
                .edges
                .iter()
                .map(|edge| {
                    (self.positions[edge.a as usize] + self.positions[edge.b as usize]) * 0.5
                })
                .collect(),
            EditorMeshSelectionMode::Face => self
                .mesh
                .faces
                .iter()
                .map(|face| {
                    let count = face.vertices.len() as f32;
                    face.vertices.iter().fold(Float3::ZERO, |center, &vertex| {
                        center + self.positions[vertex as usize] / count
                    })
                })
                .collect(),
        };
        centers
            .into_iter()
            .enumerate()
            .filter_map(|(index, center)| {
                let (x, y) = projection.project_default(center)?;
                (x >= rect.x
                    && y >= rect.y
                    && x <= rect.max_x()
                    && y <= rect.max_y()
                    && self.is_visible(center, projection, xray))
                .then_some(index)
            })
            .collect()
    }

    fn is_occluded(&self, origin: Float3, direction: Float3, depth: f32) -> bool {
        self.occluder_distance
            .as_ref()
            .and_then(|distance| distance(origin, direction))
            .is_some_and(|distance| distance < depth - self.tolerance)
    }

    fn face_hit(&self, origin: Float3, direction: Float3) -> Option<EditorMeshElementHit> {
        let mut best: Option<EditorMeshElementHit> = None;
        self.for_each_triangle(|face, triangle| {
            let [a, b, c] = triangle.map(|index| self.positions[index as usize]);
            let e1 = b - a;
            let e2 = c - a;
            let p = simd_cross(direction, e2);
            let determinant = simd_dot(e1, p);
            if determinant.abs() <= 1e-10 {
                return;
            }
            let offset = origin - a;
            let u = simd_dot(offset, p) / determinant;
            if !(-1e-6..=1.000001).contains(&u) {
                return;
            }
            let q = simd_cross(offset, e1);
            let v = simd_dot(direction, q) / determinant;
            if v >= -1e-6 && u + v <= 1.000001 {
                let distance = simd_dot(e2, q) / determinant;
                if distance >= 0.0 && distance < best.map_or(f32::INFINITY, |hit| hit.distance) {
                    best = Some(EditorMeshElementHit {
                        index: face,
                        world_position: origin + direction * distance,
                        distance,
                    });
                }
            }
        });
        best
    }
}

fn homogeneous(point: Float3) -> Float4 {
    Float4::new(point.x, point.y, point.z, 1.0)
}
