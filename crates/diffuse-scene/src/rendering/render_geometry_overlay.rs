//! Transient editor geometry (gizmos, overlays, debug draw).
//!
//! Ported from `SceneRuntime/Rendering/RenderGeometryOverlay.swift`. Positions
//! are in world space; widths and marker sizes use logical viewport pixels.
//! Never part of an authored scene asset.
//!
//! Layout: each vertex uses `Float3` (16 bytes, 16-aligned) and each colour
//! `Float4` (16 bytes, 16-aligned), the sizes MIGRATION.md §5.3 records for
//! Swift `SIMD3<Float>`/`SIMD4<Float>`. The collections are `Vec`-backed, so no
//! whole-struct size assertion applies.

use diffuse_math::simd::simd_compat::{Float2, Float3, Float4};

/// One filled triangle with optional per-edge outlines.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderGeometryTriangle {
    pub a: Float3,
    pub b: Float3,
    pub c: Float3,
    pub color: Float4,
    /// Opposite-vertex edges (BC, CA, AB); zero widths suppress GPU-only
    /// diagonals.
    pub edge_widths: Float3,
    pub edge_a: Float4,
    pub edge_b: Float4,
    pub edge_c: Float4,
}

impl RenderGeometryTriangle {
    /// `init(_:_:_:color:)` — zero edge widths and zero edge colours.
    pub fn new(a: Float3, b: Float3, c: Float3, color: Float4) -> Self {
        RenderGeometryTriangle {
            a,
            b,
            c,
            color,
            edge_widths: Float3::ZERO,
            edge_a: Float4::ZERO,
            edge_b: Float4::ZERO,
            edge_c: Float4::ZERO,
        }
    }

    /// `init(_:_:_:color:edgeWidths:edgeA:edgeB:edgeC:)`.
    // Swift's initialiser takes the same eight parameters; splitting them into
    // a struct would change the call shape without improving readability.
    #[allow(clippy::too_many_arguments)]
    pub fn with_edges(
        a: Float3,
        b: Float3,
        c: Float3,
        color: Float4,
        edge_widths: Float3,
        edge_a: Float4,
        edge_b: Float4,
        edge_c: Float4,
    ) -> Self {
        RenderGeometryTriangle {
            a,
            b,
            c,
            color,
            edge_widths,
            edge_a,
            edge_b,
            edge_c,
        }
    }
}

/// One line segment.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderGeometryLine {
    pub a: Float3,
    pub b: Float3,
    pub color: Float4,
    pub width: f32,
}

impl RenderGeometryLine {
    /// `init(_:_:color:)` — one-pixel width.
    pub fn new(a: Float3, b: Float3, color: Float4) -> Self {
        RenderGeometryLine {
            a,
            b,
            color,
            width: 1.0,
        }
    }

    /// `init(_:_:color:width:)`.
    pub fn with_width(a: Float3, b: Float3, color: Float4, width: f32) -> Self {
        RenderGeometryLine {
            a,
            b,
            color,
            width,
        }
    }
}

/// One point marker.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderGeometryPoint {
    pub position: Float3,
    pub color: Float4,
    pub size: f32,
}

impl RenderGeometryPoint {
    /// `init(_:color:)` — five-pixel marker.
    pub fn new(position: Float3, color: Float4) -> Self {
        RenderGeometryPoint {
            position,
            color,
            size: 5.0,
        }
    }

    /// `init(_:color:size:)`.
    pub fn with_size(position: Float3, color: Float4, size: f32) -> Self {
        RenderGeometryPoint {
            position,
            color,
            size,
        }
    }
}

/// A frame's worth of transient overlay geometry.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderGeometryOverlay {
    pub triangles: Vec<RenderGeometryTriangle>,
    pub lines: Vec<RenderGeometryLine>,
    pub points: Vec<RenderGeometryPoint>,
    pub xray: bool,
    pub viewport_size: Float2,
}

impl RenderGeometryOverlay {
    /// `init(viewportSize:)` — transparent to depth by default.
    pub fn new(viewport_size: Float2) -> Self {
        RenderGeometryOverlay {
            triangles: Vec::new(),
            lines: Vec::new(),
            points: Vec::new(),
            xray: false,
            viewport_size,
        }
    }

    /// `init(viewportSize:xray:)`.
    pub fn with_xray(viewport_size: Float2, xray: bool) -> Self {
        RenderGeometryOverlay {
            triangles: Vec::new(),
            lines: Vec::new(),
            points: Vec::new(),
            xray,
            viewport_size,
        }
    }

    /// True when there is nothing to draw.
    pub fn is_empty(&self) -> bool {
        self.triangles.is_empty() && self.lines.is_empty() && self.points.is_empty()
    }
}
