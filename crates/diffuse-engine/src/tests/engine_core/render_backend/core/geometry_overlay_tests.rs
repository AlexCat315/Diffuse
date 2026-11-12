//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Core/GeometryOverlayTests.swift`.

use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::passes::native_overlay_geometry::NativeOverlayGeometry;
use diffuse_scene::rendering::render_geometry_overlay::{
    RenderGeometryLine, RenderGeometryOverlay,
};

/// Homogeneous line clipping handles near/far/side planes and rejects points
/// behind the camera.
#[test]
fn clipping() {
    let near = NativeOverlayGeometry::clip_line(
        Float4::new(0.0, 0.0, -1.0, 1.0),
        Float4::new(0.0, 0.0, 0.5, 1.0),
    )
    .expect("near clip");
    assert!(near.0.z.abs() < 1.0e-6);
    assert_eq!(near.1.z, 0.5);

    let across = NativeOverlayGeometry::clip_line(
        Float4::new(-3.0, 0.0, 0.5, 1.0),
        Float4::new(3.0, 0.0, 0.5, 1.0),
    )
    .expect("side clip");
    assert!((across.0.x + 1.0).abs() < 1.0e-6);
    assert!((across.1.x - 1.0).abs() < 1.0e-6);

    assert!(
        NativeOverlayGeometry::clip_line(
            Float4::new(0.0, 0.0, 2.0, 1.0),
            Float4::new(1.0, 0.0, 3.0, 1.0),
        )
        .is_none()
    );
    assert!(
        NativeOverlayGeometry::clip_line(
            Float4::new(0.0, 0.0, 0.0, -1.0),
            Float4::new(1.0, 0.0, 0.0, -1.0),
        )
        .is_none()
    );
}

/// Pixel widths remain stable at different output resolutions and invalid input
/// is rejected.
#[test]
fn expansion() {
    let mut overlay = RenderGeometryOverlay::new(Float2::new(800.0, 600.0));
    overlay.lines = vec![RenderGeometryLine {
        a: Float3::new(-0.5, 0.0, 0.5),
        b: Float3::new(0.5, 0.0, 0.5),
        color: Float4::new(1.0, 0.5, 0.0, 1.0),
        width: 2.0,
    }];
    let vertices = NativeOverlayGeometry::make(&overlay, MATRIX_IDENTITY_FLOAT4X4, 1.0)
        .expect("overlay vertices");
    assert_eq!(vertices.len(), 6);
    assert!((vertices[2].position.y - vertices[1].position.y - 4.0 / 600.0).abs() < 1.0e-6);
    overlay.lines[0].width = f32::NAN;
    assert!(NativeOverlayGeometry::make(&overlay, MATRIX_IDENTITY_FLOAT4X4, 1.0).is_err());
    overlay.lines[0].width = 2.0;
    overlay.lines[0].a.x = f32::INFINITY;
    assert!(NativeOverlayGeometry::make(&overlay, MATRIX_IDENTITY_FLOAT4X4, 1.0).is_err());
}
