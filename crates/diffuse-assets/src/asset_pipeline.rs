//! Interleaved mesh vertex streams, mesh catalog value types and the built-in
//! cube and OBJ loader.
//!
//! Ported from `Engine/Sources/AssetPipeline/AssetPipeline.swift`.

use diffuse_math::simd::simd_compat::{
    Float2, Float3, Float4, Float4x4, mul_4x4_float4, simd_max, simd_min,
};
use diffuse_scene::rendering::render_scene::MaterialAlphaMode;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AssetPipeline;

impl AssetPipeline {
    pub fn new() -> Self {
        Self
    }

    pub fn validate_path(&self, path: &str) -> bool {
        !path.is_empty()
    }
}

/// One texture reference from an imported mesh.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshTexture {
    pub name: Option<String>,
    pub source_uri: Option<String>,
    pub mime_type: Option<String>,
    pub sampler_index: Option<i64>,
    pub data: Option<Vec<u8>>,
}

impl MeshTexture {
    /// Swift's second initialiser, which forwards `data: nil`.
    pub fn new(
        name: Option<String>,
        source_uri: Option<String>,
        mime_type: Option<String>,
        sampler_index: Option<i64>,
    ) -> Self {
        MeshTexture {
            name,
            source_uri,
            mime_type,
            sampler_index,
            data: None,
        }
    }
}

/// A material description shared by imported and authored geometry.
#[derive(Clone, Debug, PartialEq)]
pub struct MeshMaterial {
    pub name: Option<String>,
    pub base_color_factor: Float4,
    pub base_color_texture_index: Option<i64>,
    pub normal_texture_index: Option<i64>,
    /// glTF metallic-roughness map (ORM/ARM): occlusion in R, roughness in G,
    /// metallic in B. PolyHaven-style assets pack all three here.
    pub metallic_roughness_texture_index: Option<i64>,
    pub metallic_factor: f32,
    pub roughness_factor: f32,
    pub alpha_mode: MaterialAlphaMode,
    pub alpha_cutoff: f32,
    pub double_sided: bool,
}

impl Default for MeshMaterial {
    fn default() -> Self {
        MeshMaterial::new(
            None,
            Float4::new(1.0, 1.0, 1.0, 1.0),
            None,
            None,
            None,
            1.0,
            1.0,
            MaterialAlphaMode::Opaque,
            0.5,
            false,
        )
    }
}

impl MeshMaterial {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        name: Option<String>,
        base_color_factor: Float4,
        base_color_texture_index: Option<i64>,
        normal_texture_index: Option<i64>,
        metallic_roughness_texture_index: Option<i64>,
        metallic_factor: f32,
        roughness_factor: f32,
        alpha_mode: MaterialAlphaMode,
        alpha_cutoff: f32,
        double_sided: bool,
    ) -> Self {
        MeshMaterial {
            name,
            base_color_factor,
            base_color_texture_index,
            normal_texture_index,
            metallic_roughness_texture_index,
            metallic_factor,
            roughness_factor,
            alpha_mode,
            // Swift: `alphaCutoff.isFinite ? max(alphaCutoff, 0) : 0.5`.
            alpha_cutoff: if alpha_cutoff.is_finite() {
                alpha_cutoff.max(0.0)
            } else {
                0.5
            },
            double_sided,
        }
    }

    /// `MeshMaterial.fallback`.
    pub fn fallback() -> Self {
        MeshMaterial::default()
    }
}

/// One node from the glTF node hierarchy.
///
/// Stores the node's local TRS so `AnimationRuntime` can override the transform
/// of individual joints at runtime without re-importing the asset.
#[derive(Clone, Debug, PartialEq)]
pub struct MeshNode {
    pub name: Option<String>,
    /// `None` for a root node.
    pub parent_index: Option<i64>,
    pub local_translation: Float3,
    pub local_rotation: Float4,
    pub local_scale: Float3,
}

impl Default for MeshNode {
    fn default() -> Self {
        MeshNode {
            name: None,
            parent_index: None,
            local_translation: Float3::ZERO,
            local_rotation: Float4::new(0.0, 0.0, 0.0, 1.0),
            local_scale: Float3::ONE,
        }
    }
}

impl MeshNode {
    /// Composes the node's local TRS into a 4×4 matrix, matching Swift's
    /// `t * r * s` quaternion expansion exactly.
    pub fn local_matrix(&self) -> Float4x4 {
        let t = Float4x4::from_rows(&[
            Float4::new(1.0, 0.0, 0.0, self.local_translation.x),
            Float4::new(0.0, 1.0, 0.0, self.local_translation.y),
            Float4::new(0.0, 0.0, 1.0, self.local_translation.z),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ]);
        let q = self.local_rotation;
        let x2 = q.x * q.x;
        let y2 = q.y * q.y;
        let z2 = q.z * q.z;
        let xy = q.x * q.y;
        let xz = q.x * q.z;
        let yz = q.y * q.z;
        let wx = q.w * q.x;
        let wy = q.w * q.y;
        let wz = q.w * q.z;
        let r = Float4x4::from_rows(&[
            Float4::new(1.0 - 2.0 * (y2 + z2), 2.0 * (xy - wz), 2.0 * (xz + wy), 0.0),
            Float4::new(2.0 * (xy + wz), 1.0 - 2.0 * (x2 + z2), 2.0 * (yz - wx), 0.0),
            Float4::new(2.0 * (xz - wy), 2.0 * (yz + wx), 1.0 - 2.0 * (x2 + y2), 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ]);
        let s = Float4x4::from_rows(&[
            Float4::new(self.local_scale.x, 0.0, 0.0, 0.0),
            Float4::new(0.0, self.local_scale.y, 0.0, 0.0),
            Float4::new(0.0, 0.0, self.local_scale.z, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ]);
        t * r * s
    }
}

/// A skin: joint node indices plus their inverse bind matrices.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshSkin {
    pub name: Option<String>,
    pub joint_node_indices: Vec<i64>,
    pub inverse_bind_matrices: Vec<Float4x4>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MeshAnimationInterpolation {
    Linear,
    Step,
    CubicSpline,
}

impl MeshAnimationInterpolation {
    /// The persisted raw value, because Swift declared `String` raw values.
    pub fn raw_value(&self) -> &'static str {
        match self {
            MeshAnimationInterpolation::Linear => "linear",
            MeshAnimationInterpolation::Step => "step",
            MeshAnimationInterpolation::CubicSpline => "cubicSpline",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MeshAnimationPath {
    Translation,
    Rotation,
    Scale,
    Weights,
}

impl MeshAnimationPath {
    pub fn raw_value(&self) -> &'static str {
        match self {
            MeshAnimationPath::Translation => "translation",
            MeshAnimationPath::Rotation => "rotation",
            MeshAnimationPath::Scale => "scale",
            MeshAnimationPath::Weights => "weights",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeshAnimationSampler {
    pub input_times: Vec<f32>,
    pub output_values: Vec<Float4>,
    pub interpolation: MeshAnimationInterpolation,
}

impl MeshAnimationSampler {
    pub fn new(
        input_times: Vec<f32>,
        output_values: Vec<Float4>,
        interpolation: MeshAnimationInterpolation,
    ) -> Self {
        MeshAnimationSampler {
            input_times,
            output_values,
            interpolation,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeshAnimationChannel {
    pub sampler_index: i64,
    pub target_node_index: Option<i64>,
    pub path: MeshAnimationPath,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshAnimation {
    pub name: Option<String>,
    pub samplers: Vec<MeshAnimationSampler>,
    pub channels: Vec<MeshAnimationChannel>,
}

/// One draw range inside a [`MeshAsset`]'s index buffer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MeshSubmesh {
    pub index_start: u32,
    pub index_count: u32,
    pub material_index: i64,
}

impl MeshSubmesh {
    pub fn new(index_start: u32, index_count: u32, material_index: i64) -> Self {
        MeshSubmesh {
            index_start,
            index_count,
            material_index,
        }
    }
}

/// Interleaved mesh vertex stream used by runtime render backends.
///
/// Layout, in floats:
/// position3 + normal3 + color3 + uv2 + tangent4 + materialIndex1 + joints4 + weights4.
#[derive(Clone, Debug, PartialEq)]
pub struct MeshAsset {
    pub vertices: Vec<f32>,
    pub indices: Vec<u32>,
    pub name: String,
    pub materials: Vec<MeshMaterial>,
    pub textures: Vec<MeshTexture>,
    pub nodes: Vec<MeshNode>,
    pub skins: Vec<MeshSkin>,
    pub animations: Vec<MeshAnimation>,
    pub submeshes: Vec<MeshSubmesh>,
}

impl MeshAsset {
    pub const VERTEX_FLOAT_COUNT: usize = 24;
    pub const VERTEX_STRIDE: usize = Self::VERTEX_FLOAT_COUNT * size_of::<f32>();

    pub const POSITION_OFFSET: usize = 0;
    pub const NORMAL_OFFSET: usize = 12;
    pub const COLOR_OFFSET: usize = 24;
    pub const UV_OFFSET: usize = 36;
    pub const TANGENT_OFFSET: usize = 44;
    pub const MATERIAL_INDEX_OFFSET: usize = 60;
    pub const JOINTS_OFFSET: usize = 64;
    pub const WEIGHTS_OFFSET: usize = 80;

    pub const POSITION_FLOAT_OFFSET: usize = 0;
    pub const NORMAL_FLOAT_OFFSET: usize = 3;
    pub const COLOR_FLOAT_OFFSET: usize = 6;
    pub const UV_FLOAT_OFFSET: usize = 9;
    pub const TANGENT_FLOAT_OFFSET: usize = 11;
    pub const MATERIAL_INDEX_FLOAT_OFFSET: usize = 15;
    pub const JOINTS_FLOAT_OFFSET: usize = 16;
    pub const WEIGHTS_FLOAT_OFFSET: usize = 20;

    /// Swift's memberwise initialiser. `materials` defaults to the fallback
    /// material whenever the supplied list is empty.
    pub fn new(name: impl Into<String>, vertices: Vec<f32>, indices: Vec<u32>) -> Self {
        MeshAsset {
            name: name.into(),
            vertices,
            indices,
            materials: vec![MeshMaterial::fallback()],
            textures: Vec::new(),
            nodes: Vec::new(),
            skins: Vec::new(),
            animations: Vec::new(),
            submeshes: Vec::new(),
        }
    }

    pub fn with_materials(
        name: impl Into<String>,
        vertices: Vec<f32>,
        indices: Vec<u32>,
        materials: Vec<MeshMaterial>,
    ) -> Self {
        MeshAsset {
            materials: if materials.is_empty() {
                vec![MeshMaterial::fallback()]
            } else {
                materials
            },
            ..MeshAsset::new(name, vertices, indices)
        }
    }

    pub fn index_count(&self) -> u32 {
        self.indices.len() as u32
    }

    pub fn vertex_count(&self) -> usize {
        self.vertices.len() / Self::VERTEX_FLOAT_COUNT
    }

    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }

    pub fn vertex_buffer_size(&self) -> usize {
        self.vertices.len() * size_of::<f32>()
    }

    pub fn index_buffer_size(&self) -> usize {
        self.indices.len() * size_of::<u32>()
    }

    pub fn position(&self, vertex_index: i64) -> Option<Float3> {
        if vertex_index < 0 || (vertex_index as usize) >= self.vertex_count() {
            return None;
        }
        let offset = vertex_index as usize * Self::VERTEX_FLOAT_COUNT + Self::POSITION_FLOAT_OFFSET;
        Some(Float3::new(
            self.vertices[offset],
            self.vertices[offset + 1],
            self.vertices[offset + 2],
        ))
    }

    pub fn texture_coordinate(&self, vertex_index: i64) -> Option<Float2> {
        if vertex_index < 0 || (vertex_index as usize) >= self.vertex_count() {
            return None;
        }
        let offset = vertex_index as usize * Self::VERTEX_FLOAT_COUNT + Self::UV_FLOAT_OFFSET;
        Some(Float2::new(
            self.vertices[offset],
            self.vertices[offset + 1],
        ))
    }

    pub fn set_position(&mut self, position: Float3, vertex_index: i64) {
        if vertex_index < 0 || (vertex_index as usize) >= self.vertex_count() {
            return;
        }
        let offset = vertex_index as usize * Self::VERTEX_FLOAT_COUNT + Self::POSITION_FLOAT_OFFSET;
        self.vertices[offset] = position.x;
        self.vertices[offset + 1] = position.y;
        self.vertices[offset + 2] = position.z;
    }

    pub fn transform_positions(&mut self, matrix: Float4x4) {
        for vertex_index in 0..self.vertex_count() {
            let Some(position) = self.position(vertex_index as i64) else {
                continue;
            };
            let transformed =
                mul_4x4_float4(matrix, Float4::new(position.x, position.y, position.z, 1.0));
            self.set_position(
                Float3::new(transformed.x, transformed.y, transformed.z),
                vertex_index as i64,
            );
        }
    }

    /// Appends one interleaved vertex, applying Swift's argument defaults.
    #[allow(clippy::too_many_arguments)]
    pub fn append_vertex(
        vertices: &mut Vec<f32>,
        position: Float3,
        normal: Float3,
        color: Float3,
        uv: Float2,
        tangent: Float4,
        material_index: f32,
        joints: Float4,
        weights: Float4,
    ) {
        vertices.extend_from_slice(&[
            position.x,
            position.y,
            position.z,
            normal.x,
            normal.y,
            normal.z,
            color.x,
            color.y,
            color.z,
            uv.x,
            uv.y,
            tangent.x,
            tangent.y,
            tangent.z,
            tangent.w,
            material_index,
            joints.x,
            joints.y,
            joints.z,
            joints.w,
            weights.x,
            weights.y,
            weights.z,
            weights.w,
        ]);
    }

    /// `appendVertex` with Swift's memberwise defaults filled in.
    pub fn append_default_vertex(vertices: &mut Vec<f32>, position: Float3) {
        MeshAsset::append_vertex(
            vertices,
            position,
            Float3::ZERO,
            Float3::new(1.0, 1.0, 1.0),
            Float2::ZERO,
            Float4::new(1.0, 0.0, 0.0, 1.0),
            0.0,
            Float4::ZERO,
            Float4::new(1.0, 0.0, 0.0, 0.0),
        );
    }

    /// Local-space axis-aligned bounding box of all vertex positions. An empty
    /// mesh degenerates to `(zero, zero)`.
    pub fn local_bounds(&self) -> (Float3, Float3) {
        let stride = Self::VERTEX_FLOAT_COUNT;
        let mut lo = Float3::new(f32::INFINITY, f32::INFINITY, f32::INFINITY);
        let mut hi = Float3::new(f32::NEG_INFINITY, f32::NEG_INFINITY, f32::NEG_INFINITY);
        let mut i = 0;
        while i < self.vertices.len() {
            let vertex = Float3::new(self.vertices[i], self.vertices[i + 1], self.vertices[i + 2]);
            lo = simd_min(lo, vertex);
            hi = simd_max(hi, vertex);
            i += stride;
        }
        if lo.x == f32::INFINITY {
            return (Float3::ZERO, Float3::ZERO);
        }
        (lo, hi)
    }

    /// Recenters to the origin and uniform-scales the longest axis to
    /// `target_size`.
    pub fn normalize_to_unit_bounds(&mut self, target_size: f32) {
        let stride = Self::VERTEX_FLOAT_COUNT;
        let mut min_x = f32::INFINITY;
        let mut min_y = f32::INFINITY;
        let mut min_z = f32::INFINITY;
        let mut max_x = f32::NEG_INFINITY;
        let mut max_y = f32::NEG_INFINITY;
        let mut max_z = f32::NEG_INFINITY;
        let mut i = 0;
        while i < self.vertices.len() {
            let (x, y, z) = (self.vertices[i], self.vertices[i + 1], self.vertices[i + 2]);
            if x < min_x {
                min_x = x;
            }
            if x > max_x {
                max_x = x;
            }
            if y < min_y {
                min_y = y;
            }
            if y > max_y {
                max_y = y;
            }
            if z < min_z {
                min_z = z;
            }
            if z > max_z {
                max_z = z;
            }
            i += stride;
        }
        let cx = (min_x + max_x) * 0.5;
        let cy = (min_y + max_y) * 0.5;
        let cz = (min_z + max_z) * 0.5;
        let extent = (max_x - min_x).max((max_y - min_y).max(max_z - min_z));
        let scale = if extent > 0.0 {
            target_size / extent
        } else {
            1.0
        };
        let mut i = 0;
        while i < self.vertices.len() {
            self.vertices[i] = (self.vertices[i] - cx) * scale;
            self.vertices[i + 1] = (self.vertices[i + 1] - cy) * scale;
            self.vertices[i + 2] = (self.vertices[i + 2] - cz) * scale;
            i += stride;
        }
    }
}

/// Sub-mesh topology slice: usable for wireframe, debug rendering or later
/// sub-mesh reconstruction. `index_remap` maps local primitive indices onto a
/// shared vertex pool.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshTopologySlice {
    pub positions: Vec<Float3>,
    pub triangle_indices: Vec<u32>,
    pub index_remap: Option<Vec<u32>>,
}

impl MeshTopologySlice {
    pub fn new(
        positions: Vec<Float3>,
        triangle_indices: Vec<u32>,
        index_remap: Option<Vec<u32>>,
    ) -> Self {
        MeshTopologySlice {
            positions,
            triangle_indices,
            index_remap,
        }
    }
}

/// Unit cube centered at the origin, side length 1: 24 vertices, 36 indices,
/// per-face color.
pub struct BuiltinMesh;

/// `(x, y, z)` triple used by the built-in cube's literal tables.
type Vec3Lanes = (f32, f32, f32);
/// `(normal, per-face color, corners)` for one cube face.
type CubeFace = (Vec3Lanes, Vec3Lanes, [Vec3Lanes; 4]);
/// `(position, normal)` for one resolved OBJ face corner.
type ResolvedCorner = ((f32, f32, f32), (f32, f32, f32));

impl BuiltinMesh {
    pub fn cube(color: Option<Float3>) -> MeshAsset {
        // (normal, per-face color, four corners) per face, in Swift's order.
        let faces: [CubeFace; 6] = [
            (
                (1.0, 0.0, 0.0),
                (1.0, 0.2, 0.2),
                [
                    (0.5, -0.5, -0.5),
                    (0.5, 0.5, -0.5),
                    (0.5, 0.5, 0.5),
                    (0.5, -0.5, 0.5),
                ],
            ),
            (
                (-1.0, 0.0, 0.0),
                (0.2, 1.0, 0.2),
                [
                    (-0.5, -0.5, 0.5),
                    (-0.5, 0.5, 0.5),
                    (-0.5, 0.5, -0.5),
                    (-0.5, -0.5, -0.5),
                ],
            ),
            (
                (0.0, 1.0, 0.0),
                (0.2, 0.2, 1.0),
                [
                    (-0.5, 0.5, 0.5),
                    (0.5, 0.5, 0.5),
                    (0.5, 0.5, -0.5),
                    (-0.5, 0.5, -0.5),
                ],
            ),
            (
                (0.0, -1.0, 0.0),
                (1.0, 1.0, 0.2),
                [
                    (-0.5, -0.5, -0.5),
                    (0.5, -0.5, -0.5),
                    (0.5, -0.5, 0.5),
                    (-0.5, -0.5, 0.5),
                ],
            ),
            (
                (0.0, 0.0, 1.0),
                (1.0, 0.2, 1.0),
                [
                    (-0.5, -0.5, 0.5),
                    (0.5, -0.5, 0.5),
                    (0.5, 0.5, 0.5),
                    (-0.5, 0.5, 0.5),
                ],
            ),
            (
                (0.0, 0.0, -1.0),
                (0.2, 1.0, 1.0),
                [
                    (0.5, -0.5, -0.5),
                    (-0.5, -0.5, -0.5),
                    (-0.5, 0.5, -0.5),
                    (0.5, 0.5, -0.5),
                ],
            ),
        ];
        let mut vertices: Vec<f32> = Vec::new();
        let mut indices: Vec<u32> = Vec::new();
        vertices.reserve(faces.len() * 4 * MeshAsset::VERTEX_FLOAT_COUNT);
        indices.reserve(faces.len() * 6);
        for (face_index, (normal, face_color, corners)) in faces.iter().enumerate() {
            for corner in corners {
                MeshAsset::append_vertex(
                    &mut vertices,
                    Float3::new(corner.0, corner.1, corner.2),
                    Float3::new(normal.0, normal.1, normal.2),
                    color.unwrap_or_else(|| Float3::new(face_color.0, face_color.1, face_color.2)),
                    Float2::ZERO,
                    Float4::new(1.0, 0.0, 0.0, 1.0),
                    0.0,
                    Float4::ZERO,
                    Float4::new(1.0, 0.0, 0.0, 0.0),
                );
            }
            let base = (face_index * 4) as u32;
            indices.extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
        }
        MeshAsset::new("builtin.cube", vertices, indices)
    }

    /// `BuiltinMesh.cube()` with Swift's default `color: nil`.
    pub fn default_cube() -> MeshAsset {
        BuiltinMesh::cube(None)
    }
}

/// `OBJLoaderError`, one variant per Swift case.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum OBJLoaderError {
    #[error("{0}")]
    FileNotFound(String),
    #[error("{0}")]
    ParseFailed(String),
}

/// Minimal Wavefront OBJ loader. Supports `v` / `vn` / `f` only and triangulates
/// fan-style. Missing normals stay zero; colors default to white.
pub struct OBJLoader;

impl OBJLoader {
    pub fn load(path: &str) -> Result<MeshAsset, OBJLoaderError> {
        let data =
            std::fs::read(path).map_err(|_| OBJLoaderError::FileNotFound(path.to_string()))?;
        let text =
            String::from_utf8(data).map_err(|_| OBJLoaderError::FileNotFound(path.to_string()))?;
        let name = path.rsplit('/').next().unwrap_or(path).to_string();
        OBJLoader::parse(&text, name)
    }

    pub fn parse(text: &str, name: impl Into<String>) -> Result<MeshAsset, OBJLoaderError> {
        let mut positions: Vec<(f32, f32, f32)> = Vec::new();
        let mut normals: Vec<(f32, f32, f32)> = Vec::new();
        let mut vertices: Vec<f32> = Vec::new();
        let mut indices: Vec<u32> = Vec::new();
        let mut next_index: u32 = 0;
        for raw_line in text.split('\n') {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let parts: Vec<&str> = line
                .split([' ', '\t'])
                .filter(|part| !part.is_empty())
                .collect();
            let Some(head) = parts.first().copied() else {
                continue;
            };
            match head {
                "v" => {
                    if parts.len() < 4 {
                        return Err(OBJLoaderError::ParseFailed(format!("bad vertex: {line}")));
                    }
                    let (Ok(x), Ok(y), Ok(z)) = (
                        parts[1].parse::<f32>(),
                        parts[2].parse::<f32>(),
                        parts[3].parse::<f32>(),
                    ) else {
                        return Err(OBJLoaderError::ParseFailed(format!("bad vertex: {line}")));
                    };
                    positions.push((x, y, z));
                }
                "vn" => {
                    if parts.len() < 4 {
                        return Err(OBJLoaderError::ParseFailed(format!("bad normal: {line}")));
                    }
                    let (Ok(x), Ok(y), Ok(z)) = (
                        parts[1].parse::<f32>(),
                        parts[2].parse::<f32>(),
                        parts[3].parse::<f32>(),
                    ) else {
                        return Err(OBJLoaderError::ParseFailed(format!("bad normal: {line}")));
                    };
                    normals.push((x, y, z));
                }
                "f" => {
                    let face = &parts[1..];
                    if face.len() < 3 {
                        return Err(OBJLoaderError::ParseFailed(format!("bad face: {line}")));
                    }
                    let mut resolved: Vec<ResolvedCorner> = Vec::with_capacity(face.len());
                    for token in face {
                        let segments: Vec<&str> = token.split('/').collect();
                        let Some(position_index) = segments.first() else {
                            return Err(OBJLoaderError::ParseFailed(format!(
                                "bad face index: {token}"
                            )));
                        };
                        let Ok(raw) = position_index.parse::<i64>() else {
                            return Err(OBJLoaderError::ParseFailed(format!(
                                "bad face index: {token}"
                            )));
                        };
                        let index = if raw > 0 {
                            raw - 1
                        } else {
                            positions.len() as i64 + raw
                        };
                        if index < 0 || (index as usize) >= positions.len() {
                            return Err(OBJLoaderError::ParseFailed(format!(
                                "face position out of range: {token}"
                            )));
                        }
                        let mut normal = (0.0_f32, 0.0_f32, 0.0_f32);
                        if segments.len() >= 3
                            && let Ok(raw_normal) = segments[2].parse::<i64>()
                        {
                            let normal_index = if raw_normal > 0 {
                                raw_normal - 1
                            } else {
                                normals.len() as i64 + raw_normal
                            };
                            if normal_index >= 0 && (normal_index as usize) < normals.len() {
                                normal = normals[normal_index as usize];
                            }
                        }
                        resolved.push((positions[index as usize], normal));
                    }
                    for i in 1..(resolved.len() - 1) {
                        for vertex in [resolved[0], resolved[i], resolved[i + 1]] {
                            MeshAsset::append_vertex(
                                &mut vertices,
                                Float3::new(vertex.0.0, vertex.0.1, vertex.0.2),
                                Float3::new(vertex.1.0, vertex.1.1, vertex.1.2),
                                Float3::new(1.0, 1.0, 1.0),
                                Float2::ZERO,
                                Float4::new(1.0, 0.0, 0.0, 1.0),
                                0.0,
                                Float4::ZERO,
                                Float4::new(1.0, 0.0, 0.0, 0.0),
                            );
                            indices.push(next_index);
                            next_index += 1;
                        }
                    }
                }
                _ => continue,
            }
        }
        if vertices.is_empty() {
            return Err(OBJLoaderError::ParseFailed(
                "no triangles parsed".to_string(),
            ));
        }
        MeshNormalTools::fill_missing_normals(&mut vertices, &indices);
        Ok(MeshAsset::new(name, vertices, indices))
    }
}

/// Normals supplied by the OBJ (`vn` references) are left untouched; a triangle
/// whose three corners all carry a zero normal receives its face normal.
pub(crate) struct MeshNormalTools;

impl MeshNormalTools {
    pub(crate) fn fill_missing_normals(vertices: &mut [f32], indices: &[u32]) {
        let stride = MeshAsset::VERTEX_FLOAT_COUNT;
        let mut i = 0;
        while i + 2 < indices.len() {
            let i0 = indices[i] as usize * stride;
            let i1 = indices[i + 1] as usize * stride;
            let i2 = indices[i + 2] as usize * stride;
            fn has_normal(vertices: &[f32], base: usize) -> bool {
                vertices[base + MeshAsset::NORMAL_FLOAT_OFFSET] != 0.0
                    || vertices[base + MeshAsset::NORMAL_FLOAT_OFFSET + 1] != 0.0
                    || vertices[base + MeshAsset::NORMAL_FLOAT_OFFSET + 2] != 0.0
            }
            if has_normal(vertices, i0) || has_normal(vertices, i1) || has_normal(vertices, i2) {
                i += 3;
                continue;
            }
            let (p0x, p0y, p0z) = (vertices[i0], vertices[i0 + 1], vertices[i0 + 2]);
            let (p1x, p1y, p1z) = (vertices[i1], vertices[i1 + 1], vertices[i1 + 2]);
            let (p2x, p2y, p2z) = (vertices[i2], vertices[i2 + 1], vertices[i2 + 2]);
            let (ax, ay, az) = (p1x - p0x, p1y - p0y, p1z - p0z);
            let (bx, by, bz) = (p2x - p0x, p2y - p0y, p2z - p0z);
            let mut nx = ay * bz - az * by;
            let mut ny = az * bx - ax * bz;
            let mut nz = ax * by - ay * bx;
            let len = (nx * nx + ny * ny + nz * nz).sqrt();
            if len > 0.0 {
                nx /= len;
                ny /= len;
                nz /= len;
            }
            for slot in [i0, i1, i2] {
                vertices[slot + MeshAsset::NORMAL_FLOAT_OFFSET] = nx;
                vertices[slot + MeshAsset::NORMAL_FLOAT_OFFSET + 1] = ny;
                vertices[slot + MeshAsset::NORMAL_FLOAT_OFFSET + 2] = nz;
            }
            i += 3;
        }
    }
}
