//! The editor grid pass uniform block.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Lighting/GridUniforms.swift`.
//! Matches `GridUniforms` in `editor_grid.slang`: two column-major matrices
//! followed by four aligned float4 values (192 bytes, 16-aligned).

use diffuse_math::simd::simd_compat::{Float4, Float4x4, simd_inverse};
use diffuse_scene::rendering::render_scene::RenderCamera;

use super::grid_plane::EditorGridPlane;
use crate::core::frame::render_camera_matrices::RenderCameraMatrices;
use crate::core::frame::render_packet::{RenderDrawableSize, RenderPacket};
use crate::core::render_settings::Backdrop;

/// Shared GPU ABI for the WGSL and Slang grid passes. Matrices use column-major
/// storage, followed by four aligned float4 values (192 bytes in total).
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EditorGridUniforms {
    pub inverse_relative_view_projection: Float4x4,
    pub relative_view_projection: Float4x4,
    pub camera_position: Float4,
    pub viewport: Float4,
    pub plane_u: Float4,
    pub plane_v: Float4,
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<EditorGridUniforms>() == 192);
const _: () = assert!(core::mem::align_of::<EditorGridUniforms>() == 16);

impl EditorGridUniforms {
    pub fn new(
        inverse_relative_view_projection: Float4x4,
        relative_view_projection: Float4x4,
        camera_position: Float4,
        viewport: Float4,
        plane_u: Float4,
        plane_v: Float4,
    ) -> Self {
        EditorGridUniforms {
            inverse_relative_view_projection,
            relative_view_projection,
            camera_position,
            viewport,
            plane_u,
            plane_v,
        }
    }

    /// `make(packet:)` — the studio backdrop dims the grid to 0.28.
    pub fn make(packet: &RenderPacket) -> Self {
        let mut uniforms = Self::make_for_camera(
            &packet.scene.camera,
            &RenderCameraMatrices::make(&packet.scene, packet.drawable_size),
            packet.drawable_size,
            packet.render_settings.viewport.grid_spacing,
        );
        uniforms.viewport.w = if packet.render_settings.viewport.backdrop == Backdrop::Studio {
            0.28
        } else {
            1.0
        };
        uniforms
    }

    /// `make(camera:matrices:size:spacing:)`.
    pub fn make_for_camera(
        camera: &RenderCamera,
        matrices: &RenderCameraMatrices,
        size: RenderDrawableSize,
        spacing: f32,
    ) -> Self {
        let plane = EditorGridPlane::make(camera);
        // Unproject relative to the eye to preserve rays in distant scenes.
        let mut rotation = matrices.view;
        rotation.columns[3] = Float4::new(0.0, 0.0, 0.0, 1.0);
        let relative = matrices.projection * rotation;
        EditorGridUniforms::new(
            simd_inverse(relative),
            relative,
            Float4::new(camera.eye.x, camera.eye.y, camera.eye.z, 1.0),
            Float4::new(
                size.width.max(1) as f32,
                size.height.max(1) as f32,
                spacing.max(0.001),
                1.0,
            ),
            Float4::new(plane.u.x, plane.u.y, plane.u.z, plane.u_axis),
            Float4::new(plane.v.x, plane.v.y, plane.v.z, plane.v_axis),
        )
    }
}
