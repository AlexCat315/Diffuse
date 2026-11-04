//! CPU expansion and homogeneous clipping for editor overlay geometry.
//! Visibility is tested per fragment against scene depth, including partially
//! hidden edges.

use diffuse_math::simd::simd_compat::simd_length;
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, Float4x4};
use diffuse_scene::rendering::render_geometry_overlay::RenderGeometryOverlay;

use cove_graphics::rhi::RhiError;

/// Seven float4s, 112 bytes, uploaded verbatim — the pipeline stride is
/// `MemoryLayout<NativeOverlayVertex>.stride`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct NativeOverlayVertex {
    pub position: Float4,
    pub color: Float4,
    pub barycentric: Float4,
    pub widths: Float4,
    pub edge_a: Float4,
    pub edge_b: Float4,
    pub edge_c: Float4,
}

impl Default for NativeOverlayVertex {
    fn default() -> Self {
        NativeOverlayVertex {
            position: Float4::ZERO,
            color: Float4::ZERO,
            barycentric: Float4::ZERO,
            widths: Float4::ZERO,
            edge_a: Float4::ZERO,
            edge_b: Float4::ZERO,
            edge_c: Float4::ZERO,
        }
    }
}

// MIGRATION.md §5.3: the stride is baked into the pipeline's vertex layout.
const _: () = assert!(core::mem::size_of::<NativeOverlayVertex>() == 112);

pub enum NativeOverlayGeometry {}

impl NativeOverlayGeometry {
    pub const MAXIMUM_VERTICES: usize = 1_500_000;

    pub fn make(
        overlay: &RenderGeometryOverlay,
        matrix: Float4x4,
        pixel_scale: f32,
    ) -> Result<Vec<NativeOverlayVertex>, RhiError> {
        let count =
            overlay.triangles.len() * 3 + overlay.lines.len() * 6 + overlay.points.len() * 6;
        if count > Self::MAXIMUM_VERTICES
            || !pixel_scale.is_finite()
            || pixel_scale <= 0.0
            || !overlay.viewport_size.x.is_finite()
            || !overlay.viewport_size.y.is_finite()
            || overlay.viewport_size.x <= 0.0
            || overlay.viewport_size.y <= 0.0
        {
            return Err(RhiError::invalid_argument(
                "invalid geometry overlay budget or viewport",
            ));
        }
        let mut result: Vec<NativeOverlayVertex> = Vec::with_capacity(count);
        let projected = |p: Float3| -> Result<Float4, RhiError> {
            let clip = matrix * Float4::new(p.x, p.y, p.z, 1.0);
            if !(0..4).all(|lane| float4_lane(clip, lane).is_finite()) {
                return Err(RhiError::invalid_argument("non-finite geometry overlay"));
            }
            Ok(clip)
        };
        {
            // The append helper mirrors the Swift nested function: a small depth
            // offset resolves coplanar roundoff without moving the screen-space
            // contour or bringing hidden walls to the foreground.
            let append = |result: &mut Vec<NativeOverlayVertex>,
                          p: Float4,
                          color: Float4|
             -> Result<(), RhiError> {
                if !(0..4).all(|lane| float4_lane(color, lane).is_finite()) {
                    return Err(RhiError::invalid_argument("non-finite overlay color"));
                }
                let mut p = p;
                p.z -= 0.000_001 * p.w;
                result.push(NativeOverlayVertex {
                    position: p,
                    color,
                    barycentric: Float4::ZERO,
                    widths: Float4::ZERO,
                    edge_a: Float4::ZERO,
                    edge_b: Float4::ZERO,
                    edge_c: Float4::ZERO,
                });
                Ok(())
            };

            for face in &overlay.triangles {
                if !(0..3).all(|lane| {
                    let width = float3_lane(face.edge_widths, lane);
                    width.is_finite() && (0.0..=64.0).contains(&width)
                }) || ![face.edge_a, face.edge_b, face.edge_c]
                    .iter()
                    .all(|c| (0..4).all(|lane| float4_lane(*c, lane).is_finite()))
                {
                    return Err(RhiError::invalid_argument("invalid surface wire style"));
                }
                for (i, p) in [face.a, face.b, face.c].iter().enumerate() {
                    append(&mut result, projected(*p)?, face.color)?;
                    let last = result.len() - 1;
                    let mut barycentric = Float4::ZERO;
                    set_float4_lane(&mut barycentric, i, 1.0);
                    result[last].barycentric = barycentric;
                    result[last].widths = Float4::new(
                        float3_lane(face.edge_widths, 0) * pixel_scale,
                        float3_lane(face.edge_widths, 1) * pixel_scale,
                        float3_lane(face.edge_widths, 2) * pixel_scale,
                        0.0,
                    );
                    result[last].edge_a = face.edge_a;
                    result[last].edge_b = face.edge_b;
                    result[last].edge_c = face.edge_c;
                }
            }

            let quad = |result: &mut Vec<NativeOverlayVertex>,
                        corners: [Float4; 4],
                        color: Float4|
             -> Result<(), RhiError> {
                for i in [0usize, 1, 2, 0, 2, 3] {
                    append(result, corners[i], color)?;
                }
                Ok(())
            };

            for line in &overlay.lines {
                if !line.width.is_finite() || line.width <= 0.0 || line.width > 64.0 {
                    return Err(RhiError::invalid_argument("invalid overlay line width"));
                }
                let Some((a, b)) = Self::clip_line(projected(line.a)?, projected(line.b)?) else {
                    continue;
                };
                let delta = Float2::new(b.x / b.w - a.x / a.w, b.y / b.w - a.y / a.w)
                    * Float2::new(overlay.viewport_size.x, overlay.viewport_size.y);
                let length = simd_length(Float3::new(delta.x, delta.y, 0.0));
                if length <= 1e-6 {
                    continue;
                }
                let offset = Float2::new(-delta.y, delta.x) / length * line.width
                    / Float2::new(overlay.viewport_size.x, overlay.viewport_size.y);
                let oa = Float4::new(offset.x * a.w, offset.y * a.w, 0.0, 0.0);
                let ob = Float4::new(offset.x * b.w, offset.y * b.w, 0.0, 0.0);
                quad(&mut result, [a - oa, b - ob, b + ob, a + oa], line.color)?;
            }

            for point in &overlay.points {
                if !point.size.is_finite() || point.size <= 0.0 || point.size > 128.0 {
                    return Err(RhiError::invalid_argument("invalid overlay marker size"));
                }
                let p = projected(point.position)?;
                if !(p.w > 1e-6 && p.z >= 0.0 && p.z <= p.w) {
                    continue;
                }
                let r = Float2::new(
                    point.size / overlay.viewport_size.x,
                    point.size / overlay.viewport_size.y,
                ) * p.w;
                quad(
                    &mut result,
                    [
                        p + Float4::new(-r.x, -r.y, 0.0, 0.0),
                        p + Float4::new(r.x, -r.y, 0.0, 0.0),
                        p + Float4::new(r.x, r.y, 0.0, 0.0),
                        p + Float4::new(-r.x, r.y, 0.0, 0.0),
                    ],
                    point.color,
                )?;
            }
        }
        Ok(result)
    }

    pub fn clip_line(start: Float4, end: Float4) -> Option<(Float4, Float4)> {
        let mut lo: f32 = 0.0;
        let mut hi: f32 = 1.0;
        let a = [
            start.w - 1e-6,
            start.z,
            start.w - start.z,
            start.w + start.x,
            start.w - start.x,
            start.w + start.y,
            start.w - start.y,
        ];
        let b = [
            end.w - 1e-6,
            end.z,
            end.w - end.z,
            end.w + end.x,
            end.w - end.x,
            end.w + end.y,
            end.w - end.y,
        ];
        for i in 0..a.len() {
            if a[i] < 0.0 && b[i] < 0.0 {
                return None;
            }
            if (a[i] < 0.0) != (b[i] < 0.0) {
                let t = a[i] / (a[i] - b[i]);
                if a[i] < 0.0 {
                    lo = lo.max(t);
                } else {
                    hi = hi.min(t);
                }
            }
        }
        if lo > hi {
            return None;
        }
        Some((start + (end - start) * lo, start + (end - start) * hi))
    }
}

fn float4_lane(vector: Float4, lane: usize) -> f32 {
    match lane {
        0 => vector.x,
        1 => vector.y,
        2 => vector.z,
        _ => vector.w,
    }
}

fn float3_lane(vector: Float3, lane: usize) -> f32 {
    match lane {
        0 => vector.x,
        1 => vector.y,
        _ => vector.z,
    }
}

fn set_float4_lane(vector: &mut Float4, lane: usize, value: f32) {
    match lane {
        0 => vector.x = value,
        1 => vector.y = value,
        2 => vector.z = value,
        _ => vector.w = value,
    }
}
