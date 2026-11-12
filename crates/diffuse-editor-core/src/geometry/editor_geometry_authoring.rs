//! `Editor/Sources/EditorCore/Geometry/EditorGeometryAuthoring.swift`.
//!
//! The presets the Geometry menu creates. File authoring itself follows with the
//! rest of the geometry authoring surface.

use diffuse_assets::geometry::bezier_spline::{BezierControlPoint, BezierSpline};
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_math::simd::simd_compat::{Float2, Float3, Int2};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorGeometryPreset {
    Box,
    Plane,
    Curve,
}

impl EditorGeometryPreset {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorGeometryPreset; 3] = [
        EditorGeometryPreset::Box,
        EditorGeometryPreset::Plane,
        EditorGeometryPreset::Curve,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            EditorGeometryPreset::Box => "box",
            EditorGeometryPreset::Plane => "plane",
            EditorGeometryPreset::Curve => "curve",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            EditorGeometryPreset::Box => "Mesh Cube",
            EditorGeometryPreset::Plane => "Mesh Plane",
            EditorGeometryPreset::Curve => "Bezier Curve",
        }
    }

    pub fn document(self) -> GeometryDocument {
        match self {
            EditorGeometryPreset::Box => GeometryDocument::with_source(
                self.display_name(),
                GeometrySource::Box { size: Float3::ONE },
            ),
            EditorGeometryPreset::Plane => GeometryDocument::with_source(
                self.display_name(),
                GeometrySource::Grid {
                    size: Float2::new(2.0, 2.0),
                    segments: Int2::new(1, 1),
                },
            ),
            EditorGeometryPreset::Curve => {
                let spline = BezierSpline::new(
                    vec![
                        BezierControlPoint::new(
                            Float3::new(-1.0, 0.0, 0.0),
                            Float3::new(-2.0, 0.0, 0.0),
                            Float3::new(-0.5, 1.0, 0.0),
                        ),
                        BezierControlPoint::new(
                            Float3::new(1.0, 0.0, 0.0),
                            Float3::new(0.5, 1.0, 0.0),
                            Float3::new(2.0, 0.0, 0.0),
                        ),
                    ],
                    false,
                );
                let mut document = GeometryDocument::with_source(
                    self.display_name(),
                    GeometrySource::Tube {
                        spline,
                        radius: 0.1,
                        radial_segments: 12,
                        samples_per_segment: 24,
                        capped: true,
                    },
                );
                document.shading = GeometryShading::Smooth;
                document
            }
        }
    }
}
