//! Geometry modifiers: mirror, array, subdivision and solidify.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/GeometryModifier.swift`.

use std::collections::HashMap;

use diffuse_math::simd::simd_compat::{Float2, Float3, simd_length_squared};
use serde::{Deserialize, Serialize};

use crate::geometry::polygon_mesh::{
    GEOMETRY_UNIT_FALLBACK, GeometryError, GeometryLimits, PolygonEdge, PolygonFace, PolygonMesh,
    PolygonMeshEdge, geometry_finite, geometry_normal, geometry_unit,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GeometryAxis {
    X,
    Y,
    Z,
}

impl GeometryAxis {
    pub fn index(&self) -> usize {
        match self {
            GeometryAxis::X => 0,
            GeometryAxis::Y => 1,
            GeometryAxis::Z => 2,
        }
    }
}

/// The reversible operations an authored document stacks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum GeometryModifier {
    /// Reflection about a local-space plane. Only vertices on the seam weld.
    Mirror {
        axis: GeometryAxis,
        offset: f32,
        weld_distance: f32,
    },
    /// Includes the original; offset is an absolute local-space displacement.
    Array {
        count: i64,
        offset: Float3,
    },
    Subdivision {
        levels: i64,
    },
    /// Symmetric shell, with side walls along open boundary edges.
    Solidify {
        thickness: f32,
    },
}

impl GeometryModifier {
    pub fn apply(
        &self,
        source: &PolygonMesh,
        limits: GeometryLimits,
    ) -> Result<PolygonMesh, GeometryError> {
        source.validate(limits)?;
        let result = match self {
            GeometryModifier::Mirror {
                axis,
                offset,
                weld_distance,
            } => source.mirrored(axis.index(), *offset, *weld_distance, limits)?,
            GeometryModifier::Array { count, offset } => {
                source.repeated(*count, *offset, limits)?
            }
            GeometryModifier::Subdivision { levels } => {
                if !(0..=6).contains(levels) {
                    return Err(GeometryError::invalid_parameter(
                        "subdivision levels (0...6)",
                    ));
                }
                let mut mesh = source.clone();
                for _ in 0..*levels {
                    mesh = mesh.subdivided(limits)?;
                }
                mesh
            }
            GeometryModifier::Solidify { thickness } => source.solidified(*thickness, limits)?,
        };
        result.validate(limits)?;
        Ok(result)
    }
}

/// One entry of the modifier stack.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct GeometryModifierEntry {
    pub id: String,
    pub enabled: bool,
    pub operation: GeometryModifier,
}

impl GeometryModifierEntry {
    pub fn new(operation: GeometryModifier, enabled: bool, id: impl Into<String>) -> Self {
        GeometryModifierEntry {
            id: id.into(),
            enabled,
            operation,
        }
    }

    /// Swift's `init(_:enabled:id:)` with a fresh identifier.
    pub fn with_operation(operation: GeometryModifier) -> Self {
        GeometryModifierEntry {
            id: new_uuid(),
            enabled: true,
            operation,
        }
    }
}

/// Swift's `init(from:)`: older native assets did not store identity, so it is
/// derived from the stack position until the next save persists one.
impl<'de> Deserialize<'de> for GeometryModifierEntry {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            #[serde(default)]
            id: Option<String>,
            #[serde(default)]
            enabled: Option<bool>,
            operation: GeometryModifier,
        }
        // `decoder.codingPath.last?.intValue ?? 0`, captured before the map is
        // consumed. serde does not expose the path, so the caller supplies the
        // stack index through `deserialize_with`; the standalone form uses 0.
        let index = current_legacy_index();
        let raw = Raw::deserialize(deserializer)?;
        Ok(GeometryModifierEntry {
            id: raw.id.unwrap_or_else(|| format!("legacy-{index}")),
            enabled: raw.enabled.unwrap_or(true),
            operation: raw.operation,
        })
    }
}

thread_local! {
    /// Stack position the legacy-identity fallback should use.
    static LEGACY_INDEX: std::cell::Cell<i64> = const { std::cell::Cell::new(0) };
}

/// Swift reads `decoder.codingPath.last?.intValue`; serde does not expose the
/// path, so the sequence element index is bound around the decode instead.
pub(crate) fn with_legacy_index<T>(index: i64, body: impl FnOnce() -> T) -> T {
    LEGACY_INDEX.with(|slot| {
        let previous = slot.replace(index);
        let result = body();
        slot.set(previous);
        result
    })
}

fn current_legacy_index() -> i64 {
    LEGACY_INDEX.with(|slot| slot.get())
}

impl PolygonMesh {
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    fn repeated(
        &self,
        count: i64,
        offset: Float3,
        limits: GeometryLimits,
    ) -> Result<PolygonMesh, GeometryError> {
        if !(count > 0) || !geometry_finite(offset) {
            return Err(GeometryError::invalid_parameter("array count/offset"));
        }
        if self.positions.is_empty() {
            return Ok(self.clone());
        }
        let corner_count = self.corner_count();
        if !(count <= limits.max_vertices / self.positions.len() as i64)
            || !(count <= limits.max_face_corners / corner_count)
        {
            return Err(GeometryError::BudgetExceeded);
        }
        let mut points: Vec<Float3> = Vec::new();
        let mut polygons: Vec<PolygonFace> = Vec::new();
        for copy in 0..count {
            let base = points.len() as i64;
            points.extend(
                self.positions
                    .iter()
                    .map(|position| *position + offset * copy as f32),
            );
            polygons.extend(self.faces.iter().map(|face| {
                PolygonFace::new(
                    face.vertices.iter().map(|vertex| vertex + base).collect(),
                    face.uvs.clone(),
                    face.material_index,
                )
            }));
        }
        Ok(PolygonMesh::new(points, polygons))
    }

    /// The `!(x >= 0.0)` comparisons are deliberate: they are the NaN-safe
    /// spelling of Swift's `guard x >= 0 else`, which takes the fallback path for
    /// NaN as well as for negatives. Rewriting them as `x < 0.0` would let NaN
    /// through and change the geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    fn mirrored(
        &self,
        axis: usize,
        offset: f32,
        weld_distance: f32,
        limits: GeometryLimits,
    ) -> Result<PolygonMesh, GeometryError> {
        if !offset.is_finite() || !weld_distance.is_finite() || !(weld_distance >= 0.0) {
            return Err(GeometryError::invalid_parameter(
                "mirror plane/weld distance",
            ));
        }
        let corner_count = self.corner_count();
        if !((self.positions.len() as i64) <= limits.max_vertices / 2)
            || !(corner_count <= limits.max_face_corners / 2)
        {
            return Err(GeometryError::BudgetExceeded);
        }
        let mut result = self.clone();
        let mut remap: Vec<i64> = Vec::new();
        for i in 0..self.positions.len() {
            let mut point = self.positions[i];
            if (lane(point, axis) - offset).abs() <= weld_distance {
                set_lane(&mut result.positions[i], axis, offset);
                remap.push(i as i64);
            } else {
                let mirrored = offset + (offset - lane(point, axis));
                set_lane(&mut point, axis, mirrored);
                remap.push(result.positions.len() as i64);
                result.positions.push(point);
            }
        }
        for face in &self.faces {
            // A polygon already on the reflection plane is retained once.
            if face
                .vertices
                .iter()
                .all(|vertex| remap[*vertex as usize] == *vertex)
            {
                continue;
            }
            result.faces.push(PolygonFace::new(
                face.vertices
                    .iter()
                    .rev()
                    .map(|vertex| remap[*vertex as usize])
                    .collect(),
                face.uvs
                    .as_ref()
                    .map(|uvs| uvs.iter().rev().copied().collect()),
                face.material_index,
            ));
        }
        Ok(result)
    }

    /// One Catmull-Clark step.
    fn subdivided(&self, limits: GeometryLimits) -> Result<PolygonMesh, GeometryError> {
        let uses = self.edge_uses()?;
        let mut edges: Vec<PolygonMeshEdge> = uses.keys().copied().collect();
        edges.sort();
        let corner_count = self.corner_count();
        if !(corner_count <= limits.max_face_corners / 4) {
            return Err(GeometryError::BudgetExceeded);
        }
        limits.check(
            self.positions.len() as i64 + edges.len() as i64 + self.faces.len() as i64,
            corner_count * 4,
        )?;
        let mut face_points: Vec<Float3> = Vec::new();
        let mut incident_faces: Vec<Vec<usize>> = vec![Vec::new(); self.positions.len()];
        let mut incident_edges: Vec<Vec<PolygonEdge>> = vec![Vec::new(); self.positions.len()];
        for (index, face) in self.faces.iter().enumerate() {
            let count = face.vertices.len() as f32;
            face_points.push(face.vertices.iter().fold(Float3::ZERO, |acc, vertex| {
                acc + self.positions[*vertex as usize] / count
            }));
            for vertex in &face.vertices {
                incident_faces[*vertex as usize].push(index);
            }
        }
        let mut edge_indices: HashMap<PolygonEdge, i64> = HashMap::new();
        let mut edge_points: Vec<Float3> = Vec::new();
        for edge in &edges {
            incident_edges[edge.a as usize].push(*edge);
            incident_edges[edge.b as usize].push(*edge);
            edge_indices.insert(
                *edge,
                self.positions.len() as i64 + edge_points.len() as i64,
            );
            let adjacent = &uses[edge];
            let midpoint =
                self.positions[edge.a as usize] * 0.5 + self.positions[edge.b as usize] * 0.5;
            edge_points.push(if adjacent.len() == 2 {
                midpoint * 0.5
                    + face_points[adjacent[0].face as usize] * 0.25
                    + face_points[adjacent[1].face as usize] * 0.25
            } else {
                midpoint
            });
        }
        let mut points = self.positions.clone();
        for i in 0..self.positions.len() {
            let edges = &incident_edges[i];
            let adjacent = &incident_faces[i];
            if edges.is_empty() {
                continue;
            }
            let boundary: Vec<PolygonEdge> = edges
                .iter()
                .copied()
                .filter(|edge| uses[edge].len() == 1)
                .collect();
            if !boundary.is_empty() {
                if boundary.len() != 2 {
                    return Err(GeometryError::invalid_mesh("non-manifold boundary vertex"));
                }
                let neighbors: Vec<i64> = boundary
                    .iter()
                    .map(|edge| if edge.a as usize == i { edge.b } else { edge.a })
                    .collect();
                points[i] = self.positions[i] * 0.75
                    + self.positions[neighbors[0] as usize] * 0.125
                    + self.positions[neighbors[1] as usize] * 0.125;
            } else {
                let n = adjacent.len() as f32;
                let f = adjacent
                    .iter()
                    .fold(Float3::ZERO, |acc, index| acc + face_points[*index] / n);
                let r = edges.iter().fold(Float3::ZERO, |acc, edge| {
                    acc + (self.positions[edge.a as usize] * 0.5
                        + self.positions[edge.b as usize] * 0.5)
                        / n
                });
                points[i] = (f + r * 2.0 + self.positions[i] * (n - 3.0)) / n;
            }
        }
        let center_base = points.len() as i64 + edge_points.len() as i64;
        points.extend(edge_points);
        points.extend(face_points);
        let mut polygons: Vec<PolygonFace> = Vec::new();
        for (index, face) in self.faces.iter().enumerate() {
            let count = face.vertices.len();
            let center_uv = face.uvs.as_ref().map(|uvs| {
                uvs.iter()
                    .fold(Float2::ZERO, |acc, uv| acc + *uv / count as f32)
            });
            for i in 0..count {
                let previous = (i + count - 1) % count;
                let next = (i + 1) % count;
                let a = face.vertices[i];
                let b = face.vertices[next];
                let c = face.vertices[previous];
                let uv = face.uvs.as_ref().map(|uvs| {
                    vec![
                        uvs[i],
                        (uvs[i] + uvs[next]) * 0.5,
                        center_uv.expect("UVs exist when the face carries them"),
                        (uvs[previous] + uvs[i]) * 0.5,
                    ]
                });
                polygons.push(PolygonFace::new(
                    vec![
                        a,
                        edge_indices[&PolygonEdge::new(a, b)],
                        center_base + index as i64,
                        edge_indices[&PolygonEdge::new(c, a)],
                    ],
                    uv,
                    face.material_index,
                ));
            }
        }
        Ok(PolygonMesh::new(points, polygons))
    }

    /// Builds a symmetric shell with side walls around open boundaries.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    fn solidified(
        &self,
        thickness: f32,
        limits: GeometryLimits,
    ) -> Result<PolygonMesh, GeometryError> {
        if !thickness.is_finite() || !(thickness > 0.0) {
            return Err(GeometryError::invalid_parameter("positive shell thickness"));
        }
        let uses = self.edge_uses()?;
        let mut all_edges: Vec<PolygonMeshEdge> = uses.keys().copied().collect();
        all_edges.sort();
        let boundary: Vec<PolygonMeshEdge> = all_edges
            .into_iter()
            .filter(|edge| uses[edge].len() == 1)
            .collect();
        let corner_count = self.corner_count();
        if !((self.positions.len() as i64) <= limits.max_vertices / 2)
            || !(corner_count <= limits.max_face_corners / 2)
            || !((boundary.len() as i64) <= (limits.max_face_corners - corner_count * 2) / 4)
        {
            return Err(GeometryError::BudgetExceeded);
        }
        let mut normals: Vec<Float3> = vec![Float3::ZERO; self.positions.len()];
        for face in &self.faces {
            let normal = geometry_normal(face, &self.positions);
            for vertex in &face.vertices {
                normals[*vertex as usize] += normal;
            }
        }
        if !normals
            .iter()
            .all(|normal| geometry_finite(*normal) && simd_length_squared(*normal) > 1e-20)
        {
            return Err(GeometryError::invalid_mesh(
                "undefined shell normal at vertex",
            ));
        }
        let normals: Vec<Float3> = normals
            .iter()
            .map(|normal| geometry_unit(*normal, GEOMETRY_UNIT_FALLBACK))
            .collect();
        let count = self.positions.len() as i64;
        let outer: Vec<Float3> = (0..self.positions.len())
            .map(|i| self.positions[i] + normals[i] * (thickness * 0.5))
            .collect();
        let inner: Vec<Float3> = (0..self.positions.len())
            .map(|i| self.positions[i] - normals[i] * (thickness * 0.5))
            .collect();
        let mut polygons = self.faces.clone();
        polygons.extend(self.faces.iter().map(|face| {
            PolygonFace::new(
                face.vertices
                    .iter()
                    .rev()
                    .map(|vertex| vertex + count)
                    .collect(),
                face.uvs
                    .as_ref()
                    .map(|uvs| uvs.iter().rev().copied().collect()),
                face.material_index,
            )
        }));
        for edge in &boundary {
            let use_ = uses[edge][0];
            let a = use_.start;
            let b = use_.end;
            polygons.push(PolygonFace::new(
                vec![b, a, a + count, b + count],
                Some(vec![
                    Float2::new(0.0, 0.0),
                    Float2::new(1.0, 0.0),
                    Float2::new(1.0, 1.0),
                    Float2::new(0.0, 1.0),
                ]),
                self.faces[use_.face as usize].material_index,
            ));
        }
        let mut positions = outer;
        positions.extend(inner);
        Ok(PolygonMesh::new(positions, polygons))
    }
}

/// Reads one lane of a `SIMD3<Float>` by index, like Swift's subscript.
fn lane(value: Float3, axis: usize) -> f32 {
    match axis {
        0 => value.x,
        1 => value.y,
        _ => value.z,
    }
}

/// Writes one lane of a `SIMD3<Float>` by index.
fn set_lane(value: &mut Float3, axis: usize, lane_value: f32) {
    match axis {
        0 => value.x = lane_value,
        1 => value.y = lane_value,
        _ => value.z = lane_value,
    }
}

/// A fresh uppercase hyphenated identifier, matching `UUID().uuidString`'s shape.
pub(crate) fn new_uuid() -> String {
    let mut bytes = [0u8; 16];
    // Swift's UUID is random; the engine only requires uniqueness per process.
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    static SEED: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    let seed = *SEED.get_or_init(|| {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos() as u64)
            .unwrap_or(0);
        nanos ^ (std::process::id() as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
    });
    let mut state = seed
        ^ COUNTER
            .fetch_add(1, Ordering::Relaxed)
            .wrapping_mul(0x2545_F491_4F6C_DD1D);
    for chunk in bytes.chunks_mut(8) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let encoded = state.to_le_bytes();
        for (slot, byte) in chunk.iter_mut().zip(encoded.iter()) {
            *slot = *byte;
        }
    }
    // RFC 4122 version 4 / variant bits, as `UUID()` produces.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}
