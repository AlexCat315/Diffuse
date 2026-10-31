//! The GPU vertex layout for `MeshAsset`'s interleaved vertex stream.
//!
//! MIGRATION.md §5.3: the attribute offsets and the stride are baked into the
//! shaders' expectations, so they must match
//! `diffuse_assets::asset_pipeline::MeshAsset` exactly. Swift's `NativeRHI` types
//! map to `cove_graphics::rhi`, so this file reuses Cove's `VertexAttribute`,
//! `VertexBufferLayout` and `VertexFormat` instead of defining a parallel
//! vocabulary (MIGRATION.md §3).

use cove_graphics::rhi::{VertexAttribute, VertexBufferLayout, VertexFormat};
use diffuse_assets::asset_pipeline::MeshAsset;

pub enum NativeMeshVertexLayout {}

impl NativeMeshVertexLayout {
    /// Swift's `static var descriptor`: eight attributes in declaration order,
    /// offsets taken from `MeshAsset`, one interleaved buffer.
    pub fn descriptor() -> Vec<VertexAttribute> {
        vec![
            VertexAttribute::new(0, VertexFormat::Float3, MeshAsset::POSITION_OFFSET),
            VertexAttribute::new(1, VertexFormat::Float3, MeshAsset::NORMAL_OFFSET),
            VertexAttribute::new(2, VertexFormat::Float3, MeshAsset::COLOR_OFFSET),
            VertexAttribute::new(3, VertexFormat::Float2, MeshAsset::UV_OFFSET),
            VertexAttribute::new(4, VertexFormat::Float4, MeshAsset::TANGENT_OFFSET),
            VertexAttribute::new(5, VertexFormat::Float4, MeshAsset::JOINTS_OFFSET),
            VertexAttribute::new(6, VertexFormat::Float4, MeshAsset::WEIGHTS_OFFSET),
            VertexAttribute::new(7, VertexFormat::Float, MeshAsset::MATERIAL_INDEX_OFFSET),
        ]
    }

    /// The single interleaved vertex buffer.
    pub fn buffer_layouts() -> Vec<VertexBufferLayout> {
        vec![VertexBufferLayout::new(MeshAsset::VERTEX_STRIDE)]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attribute_offsets_match_the_asset_vertex_stream() {
        let attributes = NativeMeshVertexLayout::descriptor();
        let offsets: Vec<usize> = attributes
            .iter()
            .map(|attribute| attribute.offset)
            .collect();
        assert_eq!(
            offsets,
            vec![
                MeshAsset::POSITION_OFFSET,
                MeshAsset::NORMAL_OFFSET,
                MeshAsset::COLOR_OFFSET,
                MeshAsset::UV_OFFSET,
                MeshAsset::TANGENT_OFFSET,
                MeshAsset::JOINTS_OFFSET,
                MeshAsset::WEIGHTS_OFFSET,
                MeshAsset::MATERIAL_INDEX_OFFSET,
            ]
        );
    }

    #[test]
    fn every_attribute_fits_inside_the_stride() {
        let stride = MeshAsset::VERTEX_STRIDE;
        assert_eq!(NativeMeshVertexLayout::buffer_layouts()[0].stride, stride);
        for attribute in NativeMeshVertexLayout::descriptor() {
            assert!(
                attribute.offset + attribute.format.size() <= stride,
                "attribute {:?} overruns the {stride}-byte stride",
                attribute
            );
        }
        // The interleaved stream is 24 floats, exactly 96 bytes.
        assert_eq!(stride, 96);
    }

    #[test]
    fn locations_are_contiguous_from_zero() {
        let locations: Vec<u32> = NativeMeshVertexLayout::descriptor()
            .iter()
            .map(|a| a.location)
            .collect();
        assert_eq!(locations, (0..8).collect::<Vec<u32>>());
    }
}
