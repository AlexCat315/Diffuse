//! `.dmesh` geometry documents: source, modifier stack and materials.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/GeometryDocument.swift`.

use std::collections::BTreeSet;

use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, Int2};
use serde::{Deserialize, Serialize};

use crate::asset_pipeline::MeshMaterial;
use crate::geometry::bezier_spline::{BezierSpline, TubeParameters};
use crate::geometry::geometry_baker::{GeometryEvaluation, GeometryShading};
use crate::geometry::geometry_modifier::{GeometryModifierEntry, with_legacy_index};
use crate::geometry::geometry_primitives::GeometryPrimitives;
use crate::geometry::polygon_mesh::{GeometryError, GeometryLimits, PolygonMesh};

/// What a document starts from before its modifier stack runs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum GeometrySource {
    Polygon {
        mesh: PolygonMesh,
    },
    Box {
        size: Float3,
    },
    Grid {
        size: Float2,
        segments: Int2,
    },
    Tube {
        spline: BezierSpline,
        radius: f32,
        radial_segments: i64,
        samples_per_segment: i64,
        capped: bool,
    },
}

impl GeometrySource {
    pub fn evaluate(&self, limits: GeometryLimits) -> Result<PolygonMesh, GeometryError> {
        let mesh = match self {
            GeometrySource::Polygon { mesh } => mesh.clone(),
            GeometrySource::Box { size } => GeometryPrimitives::box_mesh(*size)?,
            GeometrySource::Grid { size, segments } => GeometryPrimitives::grid(
                *size,
                (i64::from(segments.x), i64::from(segments.y)),
                limits,
            )?,
            GeometrySource::Tube {
                spline,
                radius,
                radial_segments,
                samples_per_segment,
                capped,
            } => spline.tube(
                TubeParameters {
                    radius: *radius,
                    radial_segments: *radial_segments,
                    samples_per_segment: *samples_per_segment,
                    capped: *capped,
                },
                limits,
            )?,
        };
        mesh.validate(limits)?;
        Ok(mesh)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeometryMaterial {
    pub name: String,
    pub base_color: Float4,
    pub metallic: f32,
    pub roughness: f32,
}

impl Default for GeometryMaterial {
    fn default() -> Self {
        GeometryMaterial {
            name: "Material".to_string(),
            base_color: Float4::splat(1.0),
            metallic: 0.0,
            roughness: 0.5,
        }
    }
}

impl GeometryMaterial {
    pub(crate) fn bake(&self) -> Result<MeshMaterial, GeometryError> {
        let lanes = [
            self.base_color.x,
            self.base_color.y,
            self.base_color.z,
            self.base_color.w,
        ];
        let valid = lanes
            .iter()
            .all(|lane| lane.is_finite() && (0.0..=1.0).contains(lane))
            && self.metallic.is_finite()
            && self.roughness.is_finite()
            && (0.0..=1.0).contains(&self.metallic)
            && (0.0..=1.0).contains(&self.roughness);
        if !valid {
            return Err(GeometryError::invalid_parameter(
                "material color/metallic/roughness",
            ));
        }
        Ok(MeshMaterial::new(
            Some(self.name.clone()),
            self.base_color,
            None,
            None,
            None,
            self.metallic,
            self.roughness,
            diffuse_scene::rendering::render_scene::MaterialAlphaMode::Opaque,
            0.5,
            false,
        ))
    }
}

/// A native `.dmesh` asset: its source plus an ordered, reversible operation
/// stack. The asset registry evaluates it into the same mesh catalog that
/// glTF/OBJ populate.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GeometryDocument {
    pub version: i64,
    pub name: String,
    pub source: GeometrySource,
    /// Decoded through `deserialize_modifiers` so Swift's legacy-identity
    /// fallback (`decoder.codingPath.last?.intValue`) sees the stack position.
    #[serde(default, deserialize_with = "deserialize_modifiers")]
    pub modifiers: Vec<GeometryModifierEntry>,
    #[serde(default = "default_shading")]
    pub shading: GeometryShading,
    #[serde(default = "default_materials")]
    pub materials: Vec<GeometryMaterial>,
}

/// Swift reads the modifier's position from `decoder.codingPath`, which serde
/// does not expose; this visitor binds it around each element instead.
fn deserialize_modifiers<'de, D>(deserializer: D) -> Result<Vec<GeometryModifierEntry>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    struct ModifierVisitor;

    impl<'de> serde::de::Visitor<'de> for ModifierVisitor {
        type Value = Vec<GeometryModifierEntry>;

        fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
            formatter.write_str("a modifier stack")
        }

        fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
        where
            A: serde::de::SeqAccess<'de>,
        {
            let mut decoded: Vec<GeometryModifierEntry> = Vec::new();
            while let Some(entry) = with_legacy_index(decoded.len() as i64, || {
                sequence.next_element::<GeometryModifierEntry>()
            })? {
                decoded.push(entry);
            }
            Ok(decoded)
        }
    }

    deserializer.deserialize_seq(ModifierVisitor)
}

fn default_shading() -> GeometryShading {
    GeometryShading::Flat
}

fn default_materials() -> Vec<GeometryMaterial> {
    vec![GeometryMaterial::default()]
}

impl GeometryDocument {
    pub const CURRENT_VERSION: i64 = 1;
    pub const FILE_EXTENSION: &'static str = "dmesh";
    /// `load` and `save` refuse anything larger than 32 MiB.
    pub const MAXIMUM_BYTES: usize = 32 * 1024 * 1024;

    pub fn new(
        name: impl Into<String>,
        source: GeometrySource,
        modifiers: Vec<GeometryModifierEntry>,
        shading: GeometryShading,
        materials: Vec<GeometryMaterial>,
    ) -> Self {
        GeometryDocument {
            version: Self::CURRENT_VERSION,
            name: name.into(),
            source,
            modifiers,
            shading,
            materials,
        }
    }

    /// A document with Swift's defaults: flat shading, one fallback material.
    pub fn with_source(name: impl Into<String>, source: GeometrySource) -> Self {
        GeometryDocument::new(
            name,
            source,
            Vec::new(),
            GeometryShading::Flat,
            default_materials(),
        )
    }

    pub fn evaluate(&self, limits: GeometryLimits) -> Result<GeometryEvaluation, GeometryError> {
        if self.version != Self::CURRENT_VERSION {
            return Err(GeometryError::unsupported_version(self.version));
        }
        if self.modifiers.len() > 256 || self.materials.len() > 256 {
            return Err(GeometryError::BudgetExceeded);
        }
        let mut identities: BTreeSet<&str> = BTreeSet::new();
        if !self
            .modifiers
            .iter()
            .all(|entry| !entry.id.is_empty() && identities.insert(entry.id.as_str()))
        {
            return Err(GeometryError::invalid_parameter("modifier identity"));
        }
        let baked_materials: Vec<MeshMaterial> = self
            .materials
            .iter()
            .map(|material| material.bake())
            .collect::<Result<_, _>>()?;
        let mut mesh = self.source.evaluate(limits)?;
        for entry in self.modifiers.iter().filter(|entry| entry.enabled) {
            mesh = entry.operation.apply(&mesh, limits)?;
        }
        mesh.bake(&self.name, self.shading, &baked_materials, limits)
    }

    /// Reads a document, refusing anything the budget cannot hold.
    pub fn load(path: &str) -> Result<GeometryDocument, GeometryError> {
        let metadata = std::fs::metadata(path)
            .map_err(|error| GeometryError::invalid_parameter(format!("{path}: {error}")))?;
        if metadata.len() as usize > Self::MAXIMUM_BYTES {
            return Err(GeometryError::BudgetExceeded);
        }
        let data = std::fs::read(path)
            .map_err(|error| GeometryError::invalid_parameter(format!("{path}: {error}")))?;
        let document: GeometryDocument = serde_json::from_slice(&data)
            .map_err(|error| GeometryError::invalid_parameter(format!("{path}: {error}")))?;
        if document.version != Self::CURRENT_VERSION {
            return Err(GeometryError::unsupported_version(document.version));
        }
        Ok(document)
    }

    /// Validation precedes the atomic write, preserving the previous asset on
    /// failure.
    pub fn save(&self, path: &str, limits: GeometryLimits) -> Result<(), GeometryError> {
        let _ = self.evaluate(limits)?;
        let data = crate::swift_json::to_sorted_pretty(self).map_err(|error| {
            GeometryError::invalid_parameter(format!("document encoding: {error}"))
        })?;
        let bytes = data.into_bytes();
        if bytes.len() > Self::MAXIMUM_BYTES {
            return Err(GeometryError::BudgetExceeded);
        }
        cove_system::atomic_file::AtomicFile::write(
            &bytes,
            std::path::Path::new(path),
            cove_system::files::Access::Inherit,
        )
        .map_err(|error| GeometryError::invalid_parameter(format!("{path}: {error}")))
    }

    /// Decodes a modifier stack, binding the position Swift reads from
    /// `decoder.codingPath.last?.intValue` for the legacy-identity fallback.
    pub fn decode_modifiers(
        value: &serde_json::Value,
    ) -> Result<Vec<GeometryModifierEntry>, GeometryError> {
        let Some(entries) = value.as_array() else {
            return Err(GeometryError::invalid_parameter(
                "modifier stack must be an array",
            ));
        };
        let mut decoded = Vec::with_capacity(entries.len());
        for (index, entry) in entries.iter().enumerate() {
            let decoded_entry = with_legacy_index(index as i64, || {
                serde_json::from_value::<GeometryModifierEntry>(entry.clone())
            })
            .map_err(|error| {
                GeometryError::invalid_parameter(format!("modifier {index}: {error}"))
            })?;
            decoded.push(decoded_entry);
        }
        Ok(decoded)
    }
}

/// Convenience for a grid document with the given size and segment counts.
pub fn grid_document(
    name: impl Into<String>,
    size: Float2,
    segments: (i32, i32),
) -> GeometryDocument {
    GeometryDocument::with_source(
        name,
        GeometrySource::Grid {
            size,
            segments: Int2::new(segments.0, segments.1),
        },
    )
}
