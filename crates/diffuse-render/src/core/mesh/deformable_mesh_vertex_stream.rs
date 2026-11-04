//! CPU-side interleaved vertex stream for deformable surfaces.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Mesh/DeformableMeshVertexStream.swift`.
//! Keeping this conversion separate makes the physics-to-render contract
//! testable without requiring a GPU device.

use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_math::simd::simd_compat::{Float3, Float4, simd_cross, simd_normalize};
use diffuse_scene::rendering::render_scene::RenderDeformableMesh;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DeformableMeshVertexStream {
    pub vertices: Vec<f32>,
    pub indices: Vec<u32>,
}

impl DeformableMeshVertexStream {
    /// `init?(_ mesh:)` — `None` for an invalid mesh.
    pub fn from_mesh(mesh: &RenderDeformableMesh) -> Option<Self> {
        if !mesh.is_valid() {
            return None;
        }
        let mut vertices: Vec<f32> =
            Vec::with_capacity(mesh.vertex_count() * MeshAsset::VERTEX_FLOAT_COUNT);
        for index in 0..mesh.positions.len() {
            let input = mesh.normals[index];
            let normal = if simd_length_squared(input) > 0.000_001 {
                input
            } else {
                Float3::new(0.0, 1.0, 0.0)
            };
            MeshAsset::append_vertex(
                &mut vertices,
                mesh.positions[index],
                normal,
                // Swift's appendVertex defaults for the omitted arguments:
                // white color and `(1, 0, 0, 0)` skin weights.
                Float3::new(1.0, 1.0, 1.0),
                mesh.texture_coordinates[index],
                Self::tangent(normal),
                0.0,
                Float4::ZERO,
                Float4::new(1.0, 0.0, 0.0, 0.0),
            );
        }
        Some(DeformableMeshVertexStream {
            vertices,
            indices: mesh.triangle_indices.clone(),
        })
    }

    pub fn vertex_buffer_size(&self) -> u64 {
        (self.vertices.len() * core::mem::size_of::<f32>()) as u64
    }

    pub fn index_buffer_size(&self) -> u64 {
        (self.indices.len() * core::mem::size_of::<u32>()) as u64
    }

    fn tangent(normal: Float3) -> Float4 {
        let reference = if normal.y.abs() < 0.95 {
            Float3::new(0.0, 1.0, 0.0)
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let tangent = simd_normalize(simd_cross(reference, normal));
        Float4::new(tangent.x, tangent.y, tangent.z, 1.0)
    }
}
