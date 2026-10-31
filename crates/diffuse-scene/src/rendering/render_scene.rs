//! Render-facing material, mesh-handle, light and environment descriptions.
//!
//! Ported from `Engine/Sources/SceneRuntime/Rendering/RenderScene.swift`. The
//! container types (`RenderScene`, `RenderInstance`, the particle batch types) are
//! translated in the rendering batch; this module currently provides the closed
//! prefix that `diffuse-assets`, `diffuse-audio` and `diffuse-render` consume.

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use serde::{Deserialize, Serialize};

use crate::entity_id::EntityID;

/// Swift's `min(_:_:)` is `y < x ? y : x`, so a NaN operand yields the other.
#[inline]
fn swift_min(x: f32, y: f32) -> f32 {
    if y < x { y } else { x }
}

/// Swift's `max(_:_:)` is `y >= x ? y : x`, so a NaN operand yields the other.
#[inline]
fn swift_max(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}

/// Swift `max(lo, min(hi, value))`.
#[inline]
fn swift_clamp(lo: f32, hi: f32, value: f32) -> f32 {
    swift_max(lo, swift_min(hi, value))
}

/// glTF-compatible coverage semantics, shared by imported and runtime materials.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MaterialAlphaMode {
    Opaque,
    Mask,
    Blend,
}

impl MaterialAlphaMode {
    /// Swift declared explicit raw values, so these are the persisted strings —
    /// not the lowercased case names.
    pub const fn raw_value(&self) -> &'static str {
        match self {
            MaterialAlphaMode::Opaque => "OPAQUE",
            MaterialAlphaMode::Mask => "MASK",
            MaterialAlphaMode::Blend => "BLEND",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "OPAQUE" => Some(MaterialAlphaMode::Opaque),
            "MASK" => Some(MaterialAlphaMode::Mask),
            "BLEND" => Some(MaterialAlphaMode::Blend),
            _ => None,
        }
    }
}

impl Serialize for MaterialAlphaMode {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for MaterialAlphaMode {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        MaterialAlphaMode::from_raw_value(&value).ok_or_else(|| {
            serde::de::Error::custom(format!("Unknown material alpha mode: {value}"))
        })
    }
}

/// An authored simplified mesh selected at and beyond a world-space distance.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RenderMeshLOD {
    pub mesh_index: i64,
    pub minimum_distance: f32,
}

impl RenderMeshLOD {
    /// Swift clamps with `minimumDistance.isFinite ? max(0, minimumDistance) : 0`,
    /// so NaN and negatives both become `0`.
    pub fn new(mesh_index: i64, minimum_distance: f32) -> Self {
        RenderMeshLOD {
            mesh_index,
            minimum_distance: if minimum_distance.is_finite() {
                minimum_distance.max(0.0)
            } else {
                0.0
            },
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RenderMeshHandle {
    pub mesh_index: i64,
    pub asset_id: Option<String>,
    pub levels_of_detail: Vec<RenderMeshLOD>,
}

impl RenderMeshHandle {
    /// LODs are stored sorted by ascending `minimum_distance`.
    pub fn new(
        mesh_index: i64,
        asset_id: Option<String>,
        levels_of_detail: Vec<RenderMeshLOD>,
    ) -> Self {
        let mut levels_of_detail = levels_of_detail;
        levels_of_detail.sort_by(|lhs, rhs| {
            lhs.minimum_distance
                .partial_cmp(&rhs.minimum_distance)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        RenderMeshHandle {
            mesh_index,
            asset_id,
            levels_of_detail,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RenderMaterial {
    pub base_color_factor: Float4,
    pub base_color_texture_index: Option<i64>,
    pub normal_texture_index: Option<i64>,
    pub metallic_factor: f32,
    pub roughness_factor: f32,
    pub emissive_factor: Float3,
    /// `None` inherits the imported primitive's material.
    pub alpha_mode: Option<MaterialAlphaMode>,
    pub alpha_cutoff: Option<f32>,
    pub double_sided: Option<bool>,
}

impl RenderMaterial {
    /// Swift's memberwise defaults with its clamping rules applied.
    ///
    /// The arity mirrors Swift's memberwise `init` exactly; collapsing the
    /// parameters into a struct would break that 1:1 correspondence.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        base_color_factor: Float4,
        base_color_texture_index: Option<i64>,
        normal_texture_index: Option<i64>,
        metallic_factor: f32,
        roughness_factor: f32,
        emissive_factor: Float3,
        alpha_mode: Option<MaterialAlphaMode>,
        alpha_cutoff: Option<f32>,
        double_sided: Option<bool>,
    ) -> Self {
        RenderMaterial {
            base_color_factor,
            base_color_texture_index,
            normal_texture_index,
            metallic_factor: swift_clamp(0.0, 1.0, metallic_factor),
            roughness_factor: swift_clamp(0.0, 1.0, roughness_factor),
            emissive_factor,
            alpha_mode,
            // `alphaCutoff.map { $0.isFinite ? max($0, 0) : 0.5 }`.
            alpha_cutoff: alpha_cutoff.map(|value| {
                if value.is_finite() {
                    value.max(0.0)
                } else {
                    0.5
                }
            }),
            double_sided,
        }
    }
}

impl Default for RenderMaterial {
    /// Swift `static let fallback = RenderMaterial()`.
    fn default() -> Self {
        RenderMaterial {
            base_color_factor: Float4::new(1.0, 1.0, 1.0, 1.0),
            base_color_texture_index: None,
            normal_texture_index: None,
            metallic_factor: 0.0,
            roughness_factor: 1.0,
            emissive_factor: Float3::ZERO,
            alpha_mode: None,
            alpha_cutoff: None,
            double_sided: None,
        }
    }
}

impl RenderMaterial {
    pub fn fallback() -> Self {
        RenderMaterial::default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RenderLightType {
    Directional,
    Point,
    Spot,
}

impl RenderLightType {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            RenderLightType::Directional => "directional",
            RenderLightType::Point => "point",
            RenderLightType::Spot => "spot",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "directional" => Some(RenderLightType::Directional),
            "point" => Some(RenderLightType::Point),
            "spot" => Some(RenderLightType::Spot),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RenderLight {
    pub type_: RenderLightType,
    pub position: Float3,
    pub direction: Float3,
    pub color: Float3,
    pub intensity: f32,
    pub range: f32,
    pub spot_inner_angle_radians: f32,
    pub spot_outer_angle_radians: f32,
    pub cast_shadows: bool,
    pub entity: Option<EntityID>,
}

impl RenderLight {
    pub fn new(render_type: RenderLightType) -> Self {
        RenderLight {
            type_: render_type,
            position: Float3::ZERO,
            direction: Float3::new(0.0, -1.0, 0.0),
            color: Float3::new(1.0, 1.0, 1.0),
            intensity: 1.0,
            range: 10.0,
            spot_inner_angle_radians: std::f32::consts::PI / 9.0,
            spot_outer_angle_radians: std::f32::consts::PI / 6.0,
            cast_shadows: false,
            entity: None,
        }
    }

    /// Full memberwise initializer with Swift's clamping.
    #[allow(clippy::too_many_arguments)]
    pub fn with_parameters(
        render_type: RenderLightType,
        position: Float3,
        direction: Float3,
        color: Float3,
        intensity: f32,
        range: f32,
        spot_inner_angle_radians: f32,
        spot_outer_angle_radians: f32,
        cast_shadows: bool,
        entity: Option<EntityID>,
    ) -> Self {
        let outer = swift_clamp(0.001, std::f32::consts::PI, spot_outer_angle_radians);
        RenderLight {
            type_: render_type,
            position,
            direction,
            color,
            intensity: intensity.max(0.0),
            range: range.max(0.0),
            spot_outer_angle_radians: outer,
            spot_inner_angle_radians: swift_clamp(0.0, outer, spot_inner_angle_radians),
            cast_shadows,
            entity,
        }
    }
}

impl Default for RenderLight {
    fn default() -> Self {
        RenderLight::new(RenderLightType::Directional)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RenderEnvironment {
    pub ambient_color: Float3,
    pub ambient_intensity: f32,
    pub exposure: f32,
}

impl RenderEnvironment {
    pub fn new(ambient_color: Float3, ambient_intensity: f32, exposure: f32) -> Self {
        RenderEnvironment {
            ambient_color,
            ambient_intensity: ambient_intensity.max(0.0),
            exposure: exposure.max(0.0),
        }
    }
}

impl Default for RenderEnvironment {
    /// Swift `static let fallback = RenderEnvironment()`.
    fn default() -> Self {
        RenderEnvironment {
            ambient_color: Float3::new(1.0, 1.0, 1.0),
            ambient_intensity: 0.03,
            exposure: 1.0,
        }
    }
}

impl RenderEnvironment {
    pub fn fallback() -> Self {
        RenderEnvironment::default()
    }
}

/// A deformable mesh's per-frame CPU-side geometry, uploaded for skinning.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderDeformableMesh {
    pub entity: crate::entity_id::EntityID,
    pub revision: u64,
    pub topology_revision: u64,
    pub positions: Vec<diffuse_math::simd::simd_compat::Float3>,
    pub normals: Vec<diffuse_math::simd::simd_compat::Float3>,
    pub texture_coordinates: Vec<diffuse_math::simd::simd_compat::Float2>,
    pub triangle_indices: Vec<u32>,
}

impl RenderDeformableMesh {
    pub fn new(entity: crate::entity_id::EntityID, revision: u64) -> Self {
        RenderDeformableMesh {
            entity,
            revision,
            topology_revision: 0,
            positions: Vec::new(),
            normals: Vec::new(),
            texture_coordinates: Vec::new(),
            triangle_indices: Vec::new(),
        }
    }
}

/// A camera prepared for rendering.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderCamera {
    pub eye: Float3,
    pub target: Float3,
    pub up: Float3,
    pub fov_y_radians: f32,
    pub aspect_ratio: f32,
    pub near: f32,
    pub far: f32,
    pub projection: RenderCameraProjection,
    /// Full visible vertical extent in world units for orthographic views.
    pub orthographic_height: f32,
}

/// `RenderCamera.Projection` — a `String`-backed enum, so persisted values are the
/// case names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub enum RenderCameraProjection {
    #[default]
    Perspective,
    Orthographic,
}

impl RenderCameraProjection {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            RenderCameraProjection::Perspective => "perspective",
            RenderCameraProjection::Orthographic => "orthographic",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "perspective" => Some(RenderCameraProjection::Perspective),
            "orthographic" => Some(RenderCameraProjection::Orthographic),
            _ => None,
        }
    }
}

impl RenderCamera {
    /// Swift's defaulted initializer, with `perspective`, a 60-degree vertical FOV
    /// and a 0.1...1000 depth range.
    pub fn new(eye: Float3, target: Float3) -> Self {
        RenderCamera {
            eye,
            target,
            up: Float3::new(0.0, 1.0, 0.0),
            fov_y_radians: core::f32::consts::FRAC_PI_3,
            aspect_ratio: 1.0,
            near: 0.1,
            far: 1000.0,
            projection: RenderCameraProjection::Perspective,
            orthographic_height: 1.0,
        }
    }

    /// The camera used when a scene has none: looking down -Z from the origin.
    pub fn fallback() -> Self {
        RenderCamera::new(Float3::ZERO, Float3::new(0.0, 0.0, -1.0))
    }
}

impl Default for RenderCamera {
    fn default() -> Self {
        RenderCamera::fallback()
    }
}

/// One drawable instance.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderInstance {
    pub entity: Option<crate::entity_id::EntityID>,
    pub mesh: RenderMeshHandle,
    pub transform: Float4x4,
    pub color_tint: Float3,
    pub material: RenderMaterial,
}

impl RenderInstance {
    pub fn new(mesh: RenderMeshHandle, transform: Float4x4) -> Self {
        RenderInstance {
            entity: None,
            mesh,
            transform,
            color_tint: Float3::splat(1.0),
            material: RenderMaterial::fallback(),
        }
    }

    #[inline]
    pub fn mesh_index(&self) -> i64 {
        self.mesh.mesh_index
    }
}

/// The extracted render scene for one frame.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RenderScene {
    pub camera: RenderCamera,
    pub instances: Vec<RenderInstance>,
    pub lights: Vec<RenderLight>,
    pub environment: RenderEnvironment,
    /// World-space deformable surfaces keyed to `RenderInstance.entity`.
    pub deformable_meshes: Vec<RenderDeformableMesh>,
}

impl RenderScene {
    pub fn empty() -> Self {
        RenderScene {
            camera: RenderCamera::fallback(),
            instances: Vec::new(),
            lights: Vec::new(),
            environment: RenderEnvironment::fallback(),
            deformable_meshes: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alpha_mode_uses_explicit_swift_raw_values() {
        assert_eq!(MaterialAlphaMode::Opaque.raw_value(), "OPAQUE");
        assert_eq!(MaterialAlphaMode::Mask.raw_value(), "MASK");
        assert_eq!(MaterialAlphaMode::Blend.raw_value(), "BLEND");
        assert_eq!(
            MaterialAlphaMode::from_raw_value("BLEND"),
            Some(MaterialAlphaMode::Blend)
        );
        assert_eq!(MaterialAlphaMode::from_raw_value("blend"), None);
    }

    #[test]
    fn lod_distance_clamps_non_finite_and_negative() {
        assert_eq!(RenderMeshLOD::new(1, f32::NAN).minimum_distance, 0.0);
        assert_eq!(RenderMeshLOD::new(1, -4.0).minimum_distance, 0.0);
        assert_eq!(RenderMeshLOD::new(1, 2.5).minimum_distance, 2.5);
    }

    #[test]
    fn mesh_handle_sorts_lods() {
        let handle = RenderMeshHandle::new(
            0,
            None,
            vec![RenderMeshLOD::new(2, 10.0), RenderMeshLOD::new(1, 1.0)],
        );
        assert_eq!(handle.levels_of_detail[0].minimum_distance, 1.0);
        assert_eq!(handle.levels_of_detail[1].minimum_distance, 10.0);
    }

    #[test]
    fn material_clamps_factors_and_cutoff() {
        let material = RenderMaterial::new(
            Float4::new(1.0, 1.0, 1.0, 1.0),
            None,
            None,
            2.0,
            -1.0,
            Float3::ZERO,
            None,
            Some(f32::NAN),
            None,
        );
        assert_eq!(material.metallic_factor, 1.0);
        assert_eq!(material.roughness_factor, 0.0);
        // Non-finite cutoff falls back to 0.5.
        assert_eq!(material.alpha_cutoff, Some(0.5));
    }

    #[test]
    fn light_clamps_spot_angles() {
        let light = RenderLight::with_parameters(
            RenderLightType::Spot,
            Float3::ZERO,
            Float3::new(0.0, -1.0, 0.0),
            Float3::new(1.0, 1.0, 1.0),
            -1.0,
            -1.0,
            5.0,
            0.0,
            false,
            None,
        );
        assert_eq!(light.intensity, 0.0);
        assert_eq!(light.range, 0.0);
        assert_eq!(light.spot_outer_angle_radians, 0.001);
        // inner clamps to the already-clamped outer angle, not to zero.
        assert_eq!(light.spot_inner_angle_radians, 0.001);
    }
}
