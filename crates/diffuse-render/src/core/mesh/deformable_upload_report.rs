//! Per-frame deformable mesh upload accounting.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Mesh/DeformableUploadReport.swift`.

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DeformableMeshUploadReport {
    pub mesh_count: usize,
    pub vertex_count: usize,
    pub triangle_count: usize,
    pub uploaded_bytes: u64,
    pub rejected_mesh_count: usize,
}

impl DeformableMeshUploadReport {
    pub fn new(
        mesh_count: usize,
        vertex_count: usize,
        triangle_count: usize,
        uploaded_bytes: u64,
        rejected_mesh_count: usize,
    ) -> Self {
        DeformableMeshUploadReport {
            mesh_count,
            vertex_count,
            triangle_count,
            uploaded_bytes,
            rejected_mesh_count,
        }
    }
}
