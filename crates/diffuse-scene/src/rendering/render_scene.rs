//! Render-facing scene description: materials, mesh handles, lights,
//! environments, instances, deformable surfaces and particle batches.
//!
//! Ported from `Engine/Sources/SceneRuntime/Rendering/RenderScene.swift`. The
//! `RenderCamera`/`RenderScene` static-extension members (`fallbackPerspective`,
//! `empty`) live in `rendering/render_extraction.rs`, matching Swift.

use std::collections::HashSet;

use diffuse_math::simd::simd_compat::{
    Float2, Float3, Float4, Float4x4, simd_clamp_scalar, simd_cross, simd_length,
    simd_length_squared, simd_max, simd_min,
};
use serde::{Deserialize, Serialize};

use crate::entity_id::EntityID;
use crate::particles::emitter::spawning::{transform_direction, transform_point};
use crate::particles::particle_curve::ParticleCurve;
use crate::particles::particle_gpu_simulation_plan::ParticleGPUSimulationPlan;
use crate::particles::particle_types::{
    Particle, ParticleBlendMode, ParticleCollisionMode, ParticleForceMode, ParticleRenderAlignment,
    ParticleSortMode, ParticleTextureSheetPlaybackMode, ParticleVectorFieldMode,
};
use crate::rendering::render_geometry_overlay::RenderGeometryOverlay;

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
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
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

    /// `RenderMeshHandle(meshIndex:)` — no asset and no LODs.
    pub fn from_mesh_index(mesh_index: i64) -> Self {
        RenderMeshHandle::new(mesh_index, None, Vec::new())
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

/// Per-frame surface geometry streamed by a deformable simulation.
///
/// Positions are expressed in world space so the renderer must draw the matching
/// instance with an identity transform. `revision` is the content revision used
/// by render backends to avoid uploading an unchanged sleeping surface;
/// `topology_revision` changes only when indices or vertex layout change.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderDeformableMesh {
    pub entity: EntityID,
    pub revision: u64,
    pub topology_revision: u64,
    pub positions: Vec<Float3>,
    pub normals: Vec<Float3>,
    pub texture_coordinates: Vec<Float2>,
    pub triangle_indices: Vec<u32>,
}

impl RenderDeformableMesh {
    /// Zeroed scaffold used by `render_scene_extraction`; Swift has no equivalent
    /// (its only initializer is `with_geometry`, which cannot be expressed as
    /// `new` because the extractor already owns this name).
    pub fn new(entity: EntityID, revision: u64) -> Self {
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

    /// `init(entity:revision:topologyRevision:positions:triangleIndices:textureCoordinates:normals:)`.
    ///
    /// A missing `topology_revision` is derived from the indices; mismatched or
    /// missing texture coordinates become zero; missing or mismatched normals are
    /// replaced by smoothed face normals.
    #[allow(clippy::too_many_arguments)]
    pub fn with_geometry(
        entity: EntityID,
        revision: u64,
        topology_revision: Option<u64>,
        positions: Vec<Float3>,
        triangle_indices: Vec<u32>,
        texture_coordinates: Vec<Float2>,
        normals: Option<Vec<Float3>>,
    ) -> Self {
        let topology_revision =
            topology_revision.unwrap_or_else(|| Self::stable_topology_revision(&triangle_indices));
        let texture_coordinates = if texture_coordinates.len() == positions.len() {
            texture_coordinates
        } else {
            vec![Float2::ZERO; positions.len()]
        };
        let normals = match normals {
            Some(normals) if normals.len() == positions.len() => normals,
            _ => Self::smooth_normals(&positions, &triangle_indices),
        };
        RenderDeformableMesh {
            entity,
            revision,
            topology_revision,
            positions,
            normals,
            texture_coordinates,
            triangle_indices,
        }
    }

    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }

    pub fn triangle_count(&self) -> usize {
        self.triangle_indices.len() / 3
    }

    /// True when every buffer agrees and every stored float is finite.
    pub fn is_valid(&self) -> bool {
        if self.positions.is_empty()
            || self.normals.len() != self.positions.len()
            || self.texture_coordinates.len() != self.positions.len()
            || self.triangle_indices.is_empty()
            || !self.triangle_indices.len().is_multiple_of(3)
        {
            return false;
        }
        let vertex_count = self.positions.len();
        if self
            .triangle_indices
            .iter()
            .any(|index| *index as usize >= vertex_count)
        {
            return false;
        }
        self.positions.iter().all(|value| is_finite3(*value))
            && self.normals.iter().all(|value| is_finite3(*value))
            && self
                .texture_coordinates
                .iter()
                .all(|value| value.x.is_finite() && value.y.is_finite())
    }

    /// `(min, max)` over every position; zero bounds when there are no vertices.
    pub fn world_bounds(&self) -> (Float3, Float3) {
        let mut iter = self.positions.iter();
        let Some(first) = iter.next().copied() else {
            return (Float3::ZERO, Float3::ZERO);
        };
        let mut minimum = first;
        let mut maximum = first;
        for position in iter {
            minimum = simd_min(minimum, *position);
            maximum = simd_max(maximum, *position);
        }
        (minimum, maximum)
    }

    /// Area-weighted vertex normals from the triangle list.
    pub fn smooth_normals(positions: &[Float3], triangle_indices: &[u32]) -> Vec<Float3> {
        if positions.is_empty() {
            return Vec::new();
        }
        let mut result = vec![Float3::ZERO; positions.len()];
        let mut index = 0usize;
        while index + 2 < triangle_indices.len() {
            let i0 = triangle_indices[index] as usize;
            let i1 = triangle_indices[index + 1] as usize;
            let i2 = triangle_indices[index + 2] as usize;
            index += 3;
            if i0 >= positions.len() || i1 >= positions.len() || i2 >= positions.len() {
                continue;
            }
            let normal = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0]);
            // NaN-safe, matching Swift's `guard lengthSquared > eps else`.
            #[allow(clippy::neg_cmp_op_on_partial_ord)]
            let non_degenerate = simd_length_squared(normal) > 1.0e-12;
            if !non_degenerate {
                continue;
            }
            result[i0] += normal;
            result[i1] += normal;
            result[i2] += normal;
        }
        for vertex in &mut result {
            let length_squared = simd_length_squared(*vertex);
            *vertex = if length_squared > 1.0e-12 {
                *vertex / length_squared.sqrt()
            } else {
                Float3::new(0.0, 1.0, 0.0)
            };
        }
        result
    }

    /// FNV-1a over the index list followed by its count.
    pub fn stable_topology_revision(indices: &[u32]) -> u64 {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for value in indices {
            hash ^= *value as u64;
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        hash ^= indices.len() as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        hash
    }
}

fn is_finite3(value: Float3) -> bool {
    value.x.is_finite() && value.y.is_finite() && value.z.is_finite()
}

/// `RenderParticleShape: UInt32` — a raw-value enum that Swift does not make
/// `Codable`, so it has no serde representation.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum RenderParticleShape {
    #[default]
    SoftBillboard = 0,
    RibbonSegment = 1,
}

impl RenderParticleShape {
    pub const ALL: [RenderParticleShape; 2] = [
        RenderParticleShape::SoftBillboard,
        RenderParticleShape::RibbonSegment,
    ];

    pub const fn raw_value(&self) -> u32 {
        match self {
            RenderParticleShape::SoftBillboard => 0,
            RenderParticleShape::RibbonSegment => 1,
        }
    }

    pub fn from_raw_value(value: u32) -> Option<Self> {
        match value {
            0 => Some(RenderParticleShape::SoftBillboard),
            1 => Some(RenderParticleShape::RibbonSegment),
            _ => None,
        }
    }
}

/// One camera-facing billboard particle, already transformed to world space and
/// ready for the render backend.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderParticle {
    pub position: Float3,
    pub size: f32,
    pub rotation: f32,
    pub color: Float4,
    /// Ribbon end color. Billboard particles keep this equal to `color`.
    pub end_color: Float4,
    /// Texture sheet UV rect: x, y, width, height.
    pub uv_rect: Float4,
    /// Optional world-space axis used for velocity-aligned billboard rendering.
    pub alignment_axis: Float3,
    /// Multiplier applied along `alignment_axis`; 1 keeps the particle square.
    pub stretch: f32,
    /// Ribbon start width. Billboard particles keep this equal to `size`.
    pub start_size: f32,
    /// Ribbon end width. Billboard particles keep this equal to `size`.
    pub end_size: f32,
    /// Fragment alpha model used by the particle shader.
    pub shape: RenderParticleShape,
    /// Ribbon-only V coordinate offset.
    pub texture_v_offset: f32,
    /// Ribbon-only V coordinate scale; zero keeps the authored UV rect.
    pub texture_v_scale: f32,
    pub blend_mode: ParticleBlendMode,
    pub texture_path: Option<String>,
}

impl RenderParticle {
    /// Swift's memberwise initializer with its defaults and clamps. `end_color`
    /// falls back to `color`; the start/end widths fall back to `size`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        position: Float3,
        size: f32,
        rotation: f32,
        color: Float4,
        end_color: Option<Float4>,
        uv_rect: Float4,
        alignment_axis: Float3,
        stretch: f32,
        start_size: Option<f32>,
        end_size: Option<f32>,
        shape: RenderParticleShape,
        texture_v_offset: f32,
        texture_v_scale: f32,
        blend_mode: ParticleBlendMode,
        texture_path: Option<String>,
    ) -> Self {
        RenderParticle {
            position,
            size,
            rotation,
            color,
            end_color: end_color.unwrap_or(color),
            uv_rect,
            alignment_axis,
            stretch: swift_max(1.0, stretch),
            start_size: swift_max(0.0, start_size.unwrap_or(size)),
            end_size: swift_max(0.0, end_size.unwrap_or(size)),
            shape,
            texture_v_offset,
            texture_v_scale: swift_max(0.0, texture_v_scale),
            blend_mode,
            texture_path,
        }
    }

    /// `conservativeRadius` — the circumscribed billboard radius.
    pub fn conservative_radius(&self) -> f32 {
        swift_max(0.0, self.size) * swift_max(1.0, self.stretch) * std::f32::consts::FRAC_1_SQRT_2
    }
}

/// An axis-aligned world-space box accumulated from particle spheres.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderBounds {
    pub is_empty: bool,
    pub minimum: Float3,
    pub maximum: Float3,
}

impl RenderBounds {
    pub fn new(is_empty: bool, minimum: Float3, maximum: Float3) -> Self {
        RenderBounds {
            is_empty,
            minimum,
            maximum,
        }
    }

    /// Grow the box by a sphere. A negative or non-finite radius contributes zero.
    pub fn include(&mut self, center: Float3, radius: f32) {
        let r = swift_max(0.0, radius);
        let minimum = center - Float3::splat(r);
        let maximum = center + Float3::splat(r);
        if self.is_empty {
            self.minimum = minimum;
            self.maximum = maximum;
            self.is_empty = false;
        } else {
            self.minimum = simd_min(self.minimum, minimum);
            self.maximum = simd_max(self.maximum, maximum);
        }
    }
}

impl Default for RenderBounds {
    /// Swift `RenderBounds()` — empty, with zero bounds.
    fn default() -> Self {
        RenderBounds::new(true, Float3::ZERO, Float3::ZERO)
    }
}

/// The draw-order key that groups particles into one instanced draw.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ParticleRenderBatchKey {
    pub blend_mode: ParticleBlendMode,
    pub texture_path: Option<String>,
}

impl ParticleRenderBatchKey {
    pub fn new(blend_mode: ParticleBlendMode, texture_path: Option<String>) -> Self {
        ParticleRenderBatchKey {
            blend_mode,
            texture_path: normalized_particle_texture_path(&texture_path),
        }
    }

    pub fn from_particle(particle: &RenderParticle) -> Self {
        ParticleRenderBatchKey::new(particle.blend_mode, particle.texture_path.clone())
    }
}

/// A contiguous run of particles that share one batch key.
#[derive(Clone, Debug, PartialEq)]
pub struct ParticleRenderBatch {
    pub key: ParticleRenderBatchKey,
    pub start: i64,
    pub count: i64,
}

impl ParticleRenderBatch {
    pub fn new(key: ParticleRenderBatchKey, start: i64, count: i64) -> Self {
        ParticleRenderBatch {
            key,
            start: 0.max(start),
            count: 0.max(count),
        }
    }
}

/// Consecutive equal keys collapse into one batch; the order of the input list
/// is preserved so a camera-sorted particle array is drawn batched.
#[derive(Clone, Debug, PartialEq)]
pub struct ParticleRenderBatchPlan {
    pub batches: Vec<ParticleRenderBatch>,
    pub unique_texture_count: i64,
}

impl ParticleRenderBatchPlan {
    pub fn new(particles: &[RenderParticle]) -> Self {
        let mut batches: Vec<ParticleRenderBatch> = Vec::with_capacity(1.max(particles.len()));
        let mut unique_textures: HashSet<String> = HashSet::new();
        let mut current_key: Option<ParticleRenderBatchKey> = None;
        let mut current_start: i64 = 0;

        for (index, particle) in particles.iter().enumerate() {
            let index = index as i64;
            let key = ParticleRenderBatchKey::from_particle(particle);
            if let Some(texture_path) = &key.texture_path {
                unique_textures.insert(texture_path.clone());
            }
            if let Some(previous) = &current_key
                && *previous != key
            {
                batches.push(ParticleRenderBatch::new(
                    previous.clone(),
                    current_start,
                    index - current_start,
                ));
                current_start = index;
            }
            current_key = Some(key);
        }

        if let Some(key) = current_key {
            batches.push(ParticleRenderBatch::new(
                key,
                current_start,
                particles.len() as i64 - current_start,
            ));
        }

        ParticleRenderBatchPlan {
            batches,
            unique_texture_count: unique_textures.len() as i64,
        }
    }
}

/// Aggregate particle bounds and batch-count hints for culling, budgets, and
/// profiler UI.
#[derive(Clone, Debug, PartialEq)]
pub struct ParticleRenderSummary {
    pub source_particle_count: i64,
    pub submitted_source_particle_count: i64,
    pub render_budget_skipped_source_particle_count: i64,
    pub particle_count: i64,
    pub cpu_render_instance_count: i64,
    pub gpu_render_instance_count: i64,
    pub alpha_count: i64,
    pub additive_count: i64,
    pub textured_count: i64,
    pub unique_texture_count: i64,
    pub batch_count: i64,
    pub cpu_batch_count: i64,
    pub gpu_batch_count: i64,
    pub bounds: RenderBounds,
}

impl ParticleRenderSummary {
    /// The statistics initializer; every count is clamped and the derived
    /// source/CPU counts fall back to the values Swift's defaults produce.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        particle_count: i64,
        source_particle_count: Option<i64>,
        submitted_source_particle_count: Option<i64>,
        cpu_render_instance_count: Option<i64>,
        gpu_render_instance_count: i64,
        alpha_count: i64,
        additive_count: i64,
        textured_count: i64,
        unique_texture_count: i64,
        batch_count: i64,
        cpu_batch_count: Option<i64>,
        gpu_batch_count: i64,
        bounds: RenderBounds,
    ) -> Self {
        let safe_particle_count = 0.max(particle_count);
        let safe_gpu_render_instance_count = 0.max(gpu_render_instance_count);
        let safe_batch_count = 0.max(batch_count);
        let safe_gpu_batch_count = 0.max(gpu_batch_count);
        let safe_submitted_source_particle_count =
            0.max(submitted_source_particle_count.unwrap_or(safe_particle_count));
        let safe_source_particle_count = safe_submitted_source_particle_count
            .max(source_particle_count.unwrap_or(safe_submitted_source_particle_count));
        ParticleRenderSummary {
            source_particle_count: safe_source_particle_count,
            submitted_source_particle_count: safe_submitted_source_particle_count,
            render_budget_skipped_source_particle_count: 0
                .max(safe_source_particle_count - safe_submitted_source_particle_count),
            particle_count: safe_particle_count,
            cpu_render_instance_count: 0.max(
                cpu_render_instance_count
                    .unwrap_or(safe_particle_count - safe_gpu_render_instance_count),
            ),
            gpu_render_instance_count: safe_gpu_render_instance_count,
            alpha_count: 0.max(alpha_count),
            additive_count: 0.max(additive_count),
            textured_count: 0.max(textured_count),
            unique_texture_count: 0.max(unique_texture_count),
            batch_count: safe_batch_count,
            cpu_batch_count: 0
                .max(cpu_batch_count.unwrap_or(safe_batch_count - safe_gpu_batch_count)),
            gpu_batch_count: safe_gpu_batch_count,
            bounds,
        }
    }

    pub fn from_particles(particles: &[RenderParticle]) -> Self {
        ParticleRenderSummary::from_particles_with_batches(particles, &[], None, None)
    }

    /// Counts CPU particles and every GPU batch marked `render_on_gpu`, and
    /// accumulates their conservative world-space bounds.
    pub fn from_particles_with_batches(
        particles: &[RenderParticle],
        simulation_batches: &[RenderParticleSimulationBatch],
        cpu_source_particle_count: Option<i64>,
        cpu_submitted_source_particle_count: Option<i64>,
    ) -> Self {
        let mut alpha_count: i64 = 0;
        let mut additive_count: i64 = 0;
        let mut textured_count: i64 = 0;
        let mut bounds = RenderBounds::default();
        let mut unique_textures: HashSet<String> = HashSet::new();
        let cpu_render_instance_count = particles.len() as i64;
        let mut source_particle_count =
            0.max(cpu_source_particle_count.unwrap_or(particles.len() as i64));
        let mut submitted_source_particle_count =
            0.max(cpu_submitted_source_particle_count.unwrap_or(particles.len() as i64));
        let mut cpu_batch_count: i64 = 0;
        let mut current_cpu_key: Option<ParticleRenderBatchKey> = None;
        let mut gpu_render_instance_count: i64 = 0;
        let mut gpu_batch_count: i64 = 0;

        for particle in particles {
            let key = ParticleRenderBatchKey::from_particle(particle);
            if current_cpu_key.as_ref() != Some(&key) {
                cpu_batch_count += 1;
                current_cpu_key = Some(key.clone());
            }
            match particle.blend_mode {
                ParticleBlendMode::Alpha => alpha_count += 1,
                ParticleBlendMode::Additive => additive_count += 1,
            }
            if let Some(texture_path) = &key.texture_path {
                textured_count += 1;
                unique_textures.insert(texture_path.clone());
            }
            bounds.include(particle.position, particle.conservative_radius());
        }

        for batch in simulation_batches {
            if !batch.render_on_gpu {
                continue;
            }
            let source_count = batch.particle_count();
            if source_count > 0 {
                source_particle_count += source_count;
                submitted_source_particle_count += batch.render_particle_count();
            }
            let render_instance_count = batch.render_instance_count();
            if render_instance_count <= 0 {
                continue;
            }
            gpu_render_instance_count += render_instance_count;
            gpu_batch_count += 1;
            match batch.blend_mode {
                ParticleBlendMode::Alpha => alpha_count += render_instance_count,
                ParticleBlendMode::Additive => additive_count += render_instance_count,
            }
            if let Some(texture_path) = normalized_particle_texture_path(&batch.texture_path) {
                textured_count += render_instance_count;
                unique_textures.insert(texture_path);
            }
            include_rendered_gpu_particle_bounds(batch, &mut bounds);
        }

        ParticleRenderSummary::new(
            cpu_render_instance_count + gpu_render_instance_count,
            Some(source_particle_count),
            Some(submitted_source_particle_count),
            Some(cpu_render_instance_count),
            gpu_render_instance_count,
            alpha_count,
            additive_count,
            textured_count,
            unique_textures.len() as i64,
            cpu_batch_count + gpu_batch_count,
            Some(cpu_batch_count),
            gpu_batch_count,
            bounds,
        )
    }
}

impl Default for ParticleRenderSummary {
    /// Swift `ParticleRenderSummary()` — all counts zero, empty bounds.
    fn default() -> Self {
        ParticleRenderSummary::new(
            0,
            None,
            None,
            None,
            0,
            0,
            0,
            0,
            0,
            0,
            None,
            0,
            RenderBounds::default(),
        )
    }
}

/// The start/end appearance of one authored particle palette entry.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderParticleAppearance {
    pub start_size: f32,
    pub end_size: f32,
    pub start_color: Float4,
    pub end_color: Float4,
}

impl RenderParticleAppearance {
    pub fn new(start_size: f32, end_size: f32, start_color: Float4, end_color: Float4) -> Self {
        RenderParticleAppearance {
            start_size: swift_max(0.0, start_size),
            end_size: swift_max(0.0, end_size),
            start_color,
            end_color,
        }
    }
}

impl Default for RenderParticleAppearance {
    fn default() -> Self {
        RenderParticleAppearance::new(
            1.0,
            1.0,
            Float4::new(1.0, 1.0, 1.0, 1.0),
            Float4::new(1.0, 1.0, 1.0, 1.0),
        )
    }
}

/// One emitter's GPU-simulation input for this frame.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderParticleSimulationBatch {
    /// Stable source emitter identity; RenderBackend keys GPU state on it.
    pub emitter_entity: Option<EntityID>,
    pub plan: ParticleGPUSimulationPlan,
    /// Persisted particles already resident in the simulation state at frame start.
    pub particles: Vec<Particle>,
    /// Newly spawned particles appended before this frame's simulation pass.
    pub spawn_particles: Vec<Particle>,
    pub simulation_speed: f32,
    pub gravity: Float3,
    pub noise_strength: f32,
    pub noise_scale: f32,
    pub noise_speed: f32,
    pub noise_seed: u64,
    pub vector_field_mode: ParticleVectorFieldMode,
    pub vector_field_direction: Float3,
    pub vector_field_strength: f32,
    pub vector_field_scale: f32,
    pub vector_field_scroll_speed: f32,
    pub force_mode: ParticleForceMode,
    pub force_center: Float3,
    pub force_axis: Float3,
    pub force_radius: f32,
    pub force_strength: f32,
    pub force_falloff: f32,
    pub collision_mode: ParticleCollisionMode,
    pub collision_plane_y: f32,
    pub collision_restitution: f32,
    pub collision_damping: f32,
    pub render_on_gpu: bool,
    pub world_transform: Float4x4,
    pub uv_rect: Float4,
    pub texture_sheet_columns: i64,
    pub texture_sheet_rows: i64,
    pub texture_sheet_frame_count: i64,
    pub texture_sheet_frame_rate: f32,
    pub texture_sheet_playback_mode: ParticleTextureSheetPlaybackMode,
    pub texture_sheet_start_frame: i64,
    pub texture_sheet_frame_randomness: i64,
    pub start_size: f32,
    pub end_size: f32,
    pub size_curve: ParticleCurve,
    pub start_color: Float4,
    pub end_color: Float4,
    pub color_curve: ParticleCurve,
    pub uses_authored_appearance: bool,
    pub appearance_palette: Vec<RenderParticleAppearance>,
    pub blend_mode: ParticleBlendMode,
    pub texture_path: Option<String>,
    pub render_alignment: ParticleRenderAlignment,
    pub velocity_stretch_scale: f32,
    pub velocity_stretch_max: f32,
    pub sort_mode: ParticleSortMode,
    pub render_sort_priority: i64,
    /// Effective number of simulated particles to submit for rendering. A zero
    /// value keeps every live simulated particle visible.
    pub render_particle_limit: i64,
    pub render_alpha_scale: f32,
    pub trail_length: f32,
    pub trail_segments: i64,
    pub trail_end_size_scale: f32,
    pub trail_end_alpha_scale: f32,
}

impl RenderParticleSimulationBatch {
    /// Swift's defaulted memberwise initializer with every clamp applied in
    /// declaration order.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        emitter_entity: Option<EntityID>,
        plan: ParticleGPUSimulationPlan,
        particles: Vec<Particle>,
        spawn_particles: Vec<Particle>,
        simulation_speed: f32,
        gravity: Float3,
        noise_strength: f32,
        noise_scale: f32,
        noise_speed: f32,
        noise_seed: u64,
        vector_field_mode: ParticleVectorFieldMode,
        vector_field_direction: Float3,
        vector_field_strength: f32,
        vector_field_scale: f32,
        vector_field_scroll_speed: f32,
        force_mode: ParticleForceMode,
        force_center: Float3,
        force_axis: Float3,
        force_radius: f32,
        force_strength: f32,
        force_falloff: f32,
        collision_mode: ParticleCollisionMode,
        collision_plane_y: f32,
        collision_restitution: f32,
        collision_damping: f32,
        render_on_gpu: bool,
        world_transform: Float4x4,
        uv_rect: Float4,
        texture_sheet_columns: i64,
        texture_sheet_rows: i64,
        texture_sheet_frame_count: i64,
        texture_sheet_frame_rate: f32,
        texture_sheet_playback_mode: ParticleTextureSheetPlaybackMode,
        texture_sheet_start_frame: i64,
        texture_sheet_frame_randomness: i64,
        start_size: f32,
        end_size: f32,
        size_curve: ParticleCurve,
        start_color: Float4,
        end_color: Float4,
        color_curve: ParticleCurve,
        uses_authored_appearance: bool,
        appearance_palette: Vec<RenderParticleAppearance>,
        blend_mode: ParticleBlendMode,
        texture_path: Option<String>,
        render_alignment: ParticleRenderAlignment,
        velocity_stretch_scale: f32,
        velocity_stretch_max: f32,
        sort_mode: ParticleSortMode,
        render_sort_priority: i64,
        render_particle_limit: i64,
        render_alpha_scale: f32,
        trail_length: f32,
        trail_segments: i64,
        trail_end_size_scale: f32,
        trail_end_alpha_scale: f32,
    ) -> Self {
        RenderParticleSimulationBatch {
            emitter_entity,
            plan,
            particles,
            spawn_particles,
            simulation_speed: swift_max(0.0, simulation_speed),
            gravity,
            noise_strength: swift_max(0.0, noise_strength),
            noise_scale: swift_max(0.0001, noise_scale),
            noise_speed: swift_max(0.0, noise_speed),
            noise_seed,
            vector_field_mode,
            vector_field_direction,
            vector_field_strength: swift_max(0.0, vector_field_strength),
            vector_field_scale: swift_max(0.0001, vector_field_scale),
            vector_field_scroll_speed,
            force_mode,
            force_center,
            force_axis,
            force_radius: swift_max(0.0, force_radius),
            force_strength,
            force_falloff: swift_max(0.0, force_falloff),
            collision_mode,
            collision_plane_y,
            collision_restitution: simd_clamp_scalar(collision_restitution, 0.0, 1.0),
            collision_damping: simd_clamp_scalar(collision_damping, 0.0, 1.0),
            render_on_gpu,
            world_transform,
            uv_rect,
            texture_sheet_columns: 1.max(texture_sheet_columns),
            texture_sheet_rows: 1.max(texture_sheet_rows),
            texture_sheet_frame_count: 1.max(texture_sheet_frame_count),
            texture_sheet_frame_rate: swift_max(0.0, texture_sheet_frame_rate),
            texture_sheet_playback_mode,
            texture_sheet_start_frame: 0.max(texture_sheet_start_frame),
            texture_sheet_frame_randomness: 0.max(texture_sheet_frame_randomness),
            start_size: swift_max(0.0, start_size),
            end_size: swift_max(0.0, end_size),
            size_curve,
            start_color,
            end_color,
            color_curve,
            uses_authored_appearance,
            appearance_palette,
            blend_mode,
            texture_path: normalized_particle_texture_path(&texture_path),
            render_alignment,
            velocity_stretch_scale: swift_max(0.0, velocity_stretch_scale),
            velocity_stretch_max: swift_max(1.0, velocity_stretch_max),
            sort_mode,
            render_sort_priority,
            render_particle_limit: 0.max(render_particle_limit),
            render_alpha_scale: simd_clamp_scalar(render_alpha_scale, 0.0, 1.0),
            trail_length: swift_max(0.0, trail_length),
            trail_segments: 0.max(trail_segments),
            trail_end_size_scale: swift_max(0.0, trail_end_size_scale),
            trail_end_alpha_scale: simd_clamp_scalar(trail_end_alpha_scale, 0.0, 1.0),
        }
    }

    /// Persisted plus spawned particles, capped by the plan's capacity.
    pub fn particle_count(&self) -> i64 {
        let capacity = 0.max(self.plan.particle_capacity);
        let base_count = (self.particles.len() as i64).min(capacity);
        let spawn_count = (self.spawn_particles.len() as i64).min(0.max(capacity - base_count));
        base_count + spawn_count
    }

    pub fn render_instance_multiplier(&self) -> i64 {
        1 + if self.trail_length > 0.0 {
            0.max(self.trail_segments)
        } else {
            0
        }
    }

    pub fn render_particle_count(&self) -> i64 {
        let count = self.particle_count();
        if self.render_particle_limit <= 0 {
            return count;
        }
        self.render_particle_limit.min(count)
    }

    pub fn render_particle_start_index(&self) -> i64 {
        0.max(self.particle_count() - self.render_particle_count())
    }

    pub fn render_instance_count(&self) -> i64 {
        self.render_particle_count() * self.render_instance_multiplier()
    }
}

/// Accumulate the conservative bounds of the GPU particles that actually render
/// this frame (`renderParticleStartIndex ..< +renderParticleCount`).
fn include_rendered_gpu_particle_bounds(
    batch: &RenderParticleSimulationBatch,
    bounds: &mut RenderBounds,
) {
    let render_start = batch.render_particle_start_index();
    let render_end = render_start + batch.render_particle_count();
    if render_start >= render_end {
        return;
    }

    let capacity = 0.max(batch.plan.particle_capacity);
    let persisted_count = (batch.particles.len() as i64).min(capacity);
    let spawn_count = (batch.spawn_particles.len() as i64).min(0.max(capacity - persisted_count));
    let mut particle_index: i64 = 0;

    for index in 0..persisted_count {
        if particle_index >= render_end {
            return;
        }
        if particle_index >= render_start {
            include_gpu_particle(&batch.particles[index as usize], batch, bounds);
        }
        particle_index += 1;
    }

    for index in 0..spawn_count {
        if particle_index >= render_end {
            return;
        }
        if particle_index >= render_start {
            include_gpu_particle(&batch.spawn_particles[index as usize], batch, bounds);
        }
        particle_index += 1;
    }
}

fn include_gpu_particle(
    particle: &Particle,
    batch: &RenderParticleSimulationBatch,
    bounds: &mut RenderBounds,
) {
    let center = transform_point(particle.position, &batch.world_transform);
    let world_velocity = transform_direction(particle.velocity, &batch.world_transform);
    let radius = gpu_particle_conservative_radius(
        gpu_particle_conservative_size(particle, batch),
        simd_length(world_velocity),
        batch,
    );
    bounds.include(center, radius);
}

/// Trimmed, non-empty texture paths only — `normalizedParticleTexturePath`.
fn normalized_particle_texture_path(path: &Option<String>) -> Option<String> {
    let path = path.as_ref()?.trim();
    if path.is_empty() {
        return None;
    }
    Some(path.to_string())
}

fn gpu_particle_conservative_size(
    particle: &Particle,
    batch: &RenderParticleSimulationBatch,
) -> f32 {
    if !batch.uses_authored_appearance {
        return swift_max(0.0, particle.size);
    }
    let appearance = gpu_particle_appearance(particle, batch);
    let (range_min, range_max) = batch.size_curve.conservative_value_range();
    let delta = appearance.end_size - appearance.start_size;
    let authored_size = swift_max(
        0.0,
        swift_max(
            appearance.start_size + delta * range_min,
            appearance.start_size + delta * range_max,
        ),
    ) * swift_max(0.0, particle.size_scale);
    swift_max(0.0, swift_max(particle.size, authored_size))
}

fn gpu_particle_appearance(
    particle: &Particle,
    batch: &RenderParticleSimulationBatch,
) -> RenderParticleAppearance {
    if batch.appearance_palette.is_empty() {
        return RenderParticleAppearance::new(
            batch.start_size,
            batch.end_size,
            batch.start_color,
            batch.end_color,
        );
    }
    let index = particle.appearance_index as usize;
    if index < batch.appearance_palette.len() {
        return batch.appearance_palette[index];
    }
    if batch.appearance_palette.len() > 1 {
        return batch.appearance_palette[1];
    }
    batch.appearance_palette[0]
}

fn gpu_particle_conservative_radius(
    size: f32,
    velocity_magnitude: f32,
    batch: &RenderParticleSimulationBatch,
) -> f32 {
    let safe_velocity = if velocity_magnitude.is_finite() {
        swift_max(0.0, velocity_magnitude)
    } else {
        0.0
    };
    let stretch = match batch.render_alignment {
        ParticleRenderAlignment::Billboard => 1.0,
        ParticleRenderAlignment::Velocity => swift_min(
            batch.velocity_stretch_max,
            swift_max(1.0, 1.0 + safe_velocity * batch.velocity_stretch_scale),
        ),
    };
    let billboard_radius =
        swift_max(0.0, size) * swift_max(1.0, stretch) * std::f32::consts::FRAC_1_SQRT_2;
    let trail_radius = if batch.trail_length > 0.0 {
        safe_velocity * batch.trail_length
    } else {
        0.0
    };
    billboard_radius + trail_radius
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

impl Serialize for RenderCameraProjection {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for RenderCameraProjection {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        RenderCameraProjection::from_raw_value(&value)
            .ok_or_else(|| serde::de::Error::custom(format!("Unknown camera projection: {value}")))
    }
}

impl RenderCamera {
    /// Swift's defaulted initializer: +Y up, a 45-degree vertical FOV, a 1:1
    /// aspect ratio, a 0.1...100 depth range, perspective projection and a
    /// 10-unit orthographic height.
    pub fn new(eye: Float3, target: Float3) -> Self {
        RenderCamera {
            eye,
            target,
            up: Float3::new(0.0, 1.0, 0.0),
            fov_y_radians: core::f32::consts::FRAC_PI_4,
            aspect_ratio: 1.0,
            near: 0.1,
            far: 100.0,
            projection: RenderCameraProjection::Perspective,
            orthographic_height: 10.0,
        }
    }

    /// The full memberwise initializer with Swift's aspect-ratio and
    /// orthographic-height sanitation.
    #[allow(clippy::too_many_arguments)]
    pub fn with_parameters(
        eye: Float3,
        target: Float3,
        up: Float3,
        fov_y_radians: f32,
        aspect_ratio: f32,
        near: f32,
        far: f32,
        projection: RenderCameraProjection,
        orthographic_height: f32,
    ) -> Self {
        RenderCamera {
            eye,
            target,
            up,
            fov_y_radians,
            aspect_ratio: swift_max(0.001, aspect_ratio),
            near,
            far,
            projection,
            orthographic_height: Self::sanitized_orthographic_height(orthographic_height),
        }
    }

    /// `sanitizedOrthographicHeight` — non-finite values fall back to 10 and the
    /// result is clamped to `0.01...10_000`.
    pub fn sanitized_orthographic_height(value: f32) -> f32 {
        if value.is_finite() {
            swift_clamp(0.01, 10_000.0, value)
        } else {
            10.0
        }
    }

    /// The camera used when a scene has none — Swift's `fallbackPerspective`.
    pub fn fallback() -> Self {
        RenderCamera::new(Float3::new(0.0, 2.4, 7.5), Float3::ZERO)
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

    /// The full memberwise initializer.
    pub fn with_parameters(
        mesh: RenderMeshHandle,
        transform: Float4x4,
        color_tint: Float3,
        material: RenderMaterial,
        entity: Option<EntityID>,
    ) -> Self {
        RenderInstance {
            entity,
            mesh,
            transform,
            color_tint,
            material,
        }
    }

    /// `init(meshIndex:transform:colorTint:material:entity:)`.
    pub fn from_mesh_index(
        mesh_index: i64,
        transform: Float4x4,
        color_tint: Float3,
        material: RenderMaterial,
        entity: Option<EntityID>,
    ) -> Self {
        RenderInstance::with_parameters(
            RenderMeshHandle::from_mesh_index(mesh_index),
            transform,
            color_tint,
            material,
            entity,
        )
    }

    #[inline]
    pub fn mesh_index(&self) -> i64 {
        self.mesh.mesh_index
    }

    #[inline]
    pub fn set_mesh_index(&mut self, value: i64) {
        self.mesh.mesh_index = value;
    }
}

/// The extracted render scene for one frame.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RenderScene {
    pub geometry_overlays: Vec<RenderGeometryOverlay>,
    pub camera: RenderCamera,
    pub instances: Vec<RenderInstance>,
    pub lights: Vec<RenderLight>,
    pub environment: RenderEnvironment,
    /// World-space deformable surfaces keyed to `RenderInstance.entity`.
    pub deformable_meshes: Vec<RenderDeformableMesh>,
    /// World-space billboard particles, pre-sorted back-to-front for the camera.
    pub particles: Vec<RenderParticle>,
    /// GPU-simulation input batches extracted from authored particle emitters.
    pub particle_simulation_batches: Vec<RenderParticleSimulationBatch>,
    /// Aggregate particle bounds and batch-count hints for culling, budgets, and
    /// profiler UI.
    pub particle_summary: ParticleRenderSummary,
}

impl RenderScene {
    /// Swift's initializer: deformable meshes are sorted by raw entity value and
    /// an absent summary is derived from the particle lists. Overlays always
    /// start empty because Swift's initializer does not accept them.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        camera: RenderCamera,
        instances: Vec<RenderInstance>,
        lights: Vec<RenderLight>,
        environment: RenderEnvironment,
        deformable_meshes: Vec<RenderDeformableMesh>,
        particles: Vec<RenderParticle>,
        particle_simulation_batches: Vec<RenderParticleSimulationBatch>,
        particle_summary: Option<ParticleRenderSummary>,
    ) -> Self {
        let mut deformable_meshes = deformable_meshes;
        deformable_meshes.sort_by_key(|lhs| lhs.entity.raw_value());
        let particle_summary = particle_summary.unwrap_or_else(|| {
            ParticleRenderSummary::from_particles_with_batches(
                &particles,
                &particle_simulation_batches,
                None,
                None,
            )
        });
        RenderScene {
            geometry_overlays: Vec::new(),
            camera,
            instances,
            lights,
            environment,
            deformable_meshes,
            particles,
            particle_simulation_batches,
            particle_summary,
        }
    }

    /// `RenderScene.empty` — the fallback camera and nothing else.
    pub fn empty() -> Self {
        RenderScene {
            geometry_overlays: Vec::new(),
            camera: RenderCamera::fallback(),
            instances: Vec::new(),
            lights: Vec::new(),
            environment: RenderEnvironment::fallback(),
            deformable_meshes: Vec::new(),
            particles: Vec::new(),
            particle_simulation_batches: Vec::new(),
            particle_summary: ParticleRenderSummary::default(),
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

    fn test_particle(texture_path: Option<&str>) -> RenderParticle {
        RenderParticle::new(
            Float3::ZERO,
            1.0,
            0.0,
            Float4::new(1.0, 1.0, 1.0, 1.0),
            None,
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float3::ZERO,
            1.0,
            None,
            None,
            RenderParticleShape::SoftBillboard,
            0.0,
            0.0,
            ParticleBlendMode::Alpha,
            texture_path.map(|value| value.to_string()),
        )
    }

    #[test]
    fn particle_batch_plan_groups_consecutive_keys() {
        let particles = vec![
            test_particle(Some(" smoke.png ")),
            test_particle(Some("spark.png")),
            test_particle(Some("smoke.png")),
        ];
        let plan = ParticleRenderBatchPlan::new(&particles);
        assert_eq!(
            plan.batches
                .iter()
                .map(|batch| batch.start)
                .collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
        assert_eq!(
            plan.batches
                .iter()
                .map(|batch| batch.count)
                .collect::<Vec<_>>(),
            vec![1, 1, 1]
        );
        assert_eq!(
            plan.batches[0].key.texture_path.as_deref(),
            Some("smoke.png")
        );
        assert_eq!(plan.unique_texture_count, 2);
    }

    #[test]
    fn summary_counts_cpu_batches_and_textures() {
        let particles = vec![
            test_particle(Some("smoke.png")),
            test_particle(Some(" smoke.png ")),
        ];
        let summary = ParticleRenderSummary::from_particles(&particles);
        assert_eq!(summary.particle_count, 2);
        assert_eq!(summary.cpu_render_instance_count, 2);
        assert_eq!(summary.gpu_render_instance_count, 0);
        assert_eq!(summary.batch_count, 1);
        assert_eq!(summary.cpu_batch_count, 1);
        assert_eq!(summary.gpu_batch_count, 0);
        assert_eq!(summary.textured_count, 2);
        assert_eq!(summary.unique_texture_count, 1);
        assert_eq!(summary.source_particle_count, 2);
        assert_eq!(summary.render_budget_skipped_source_particle_count, 0);
        assert!(!summary.bounds.is_empty);
    }

    fn gpu_batch() -> RenderParticleSimulationBatch {
        use diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4;

        RenderParticleSimulationBatch {
            emitter_entity: None,
            plan: ParticleGPUSimulationPlan {
                backend: crate::particles::particle_types::ParticleSimulationBackend::GpuIfSupported,
                status: crate::particles::particle_gpu_simulation_plan::ParticleGPUSimulationPlanStatus::Supported,
                particle_capacity: 4,
                workgroup_size: 64,
                dispatch_workgroups: 1,
                unsupported_reasons: Vec::new(),
            },
            particles: vec![Particle::new(
                Float3::ZERO,
                Float3::ZERO,
                0.0,
                1.0,
                1.0,
                0.0,
                0.0,
                1.0,
                Float4::new(1.0, 1.0, 1.0, 1.0),
                0,
                0,
                0,
            )],
            spawn_particles: Vec::new(),
            simulation_speed: 1.0,
            gravity: Float3::ZERO,
            noise_strength: 0.0,
            noise_scale: 1.0,
            noise_speed: 0.0,
            noise_seed: 0,
            vector_field_mode: ParticleVectorFieldMode::None,
            vector_field_direction: Float3::new(0.0, 1.0, 0.0),
            vector_field_strength: 0.0,
            vector_field_scale: 1.0,
            vector_field_scroll_speed: 0.0,
            force_mode: ParticleForceMode::None,
            force_center: Float3::ZERO,
            force_axis: Float3::new(0.0, 1.0, 0.0),
            force_radius: 0.0,
            force_strength: 0.0,
            force_falloff: 1.0,
            collision_mode: ParticleCollisionMode::None,
            collision_plane_y: 0.0,
            collision_restitution: 0.5,
            collision_damping: 0.0,
            render_on_gpu: true,
            world_transform: MATRIX_IDENTITY_FLOAT4X4,
            uv_rect: Float4::new(0.0, 0.0, 1.0, 1.0),
            texture_sheet_columns: 1,
            texture_sheet_rows: 1,
            texture_sheet_frame_count: 1,
            texture_sheet_frame_rate: 0.0,
            texture_sheet_playback_mode: ParticleTextureSheetPlaybackMode::Automatic,
            texture_sheet_start_frame: 0,
            texture_sheet_frame_randomness: 0,
            start_size: 1.0,
            end_size: 1.0,
            size_curve: ParticleCurve::Linear,
            start_color: Float4::new(1.0, 1.0, 1.0, 1.0),
            end_color: Float4::new(1.0, 1.0, 1.0, 1.0),
            color_curve: ParticleCurve::Linear,
            uses_authored_appearance: true,
            appearance_palette: Vec::new(),
            blend_mode: ParticleBlendMode::Alpha,
            texture_path: Some(" smoke ".to_string()),
            render_alignment: ParticleRenderAlignment::Billboard,
            velocity_stretch_scale: 0.0,
            velocity_stretch_max: 8.0,
            sort_mode: ParticleSortMode::DistanceDescending,
            render_sort_priority: 0,
            render_particle_limit: 0,
            render_alpha_scale: 1.0,
            trail_length: 1.0,
            trail_segments: 2,
            trail_end_size_scale: 0.5,
            trail_end_alpha_scale: 0.0,
        }
    }

    #[test]
    fn summary_counts_gpu_batches_and_trails() {
        let batch = gpu_batch();
        assert_eq!(batch.particle_count(), 1);
        assert_eq!(batch.render_instance_count(), 3);
        let summary = ParticleRenderSummary::from_particles_with_batches(&[], &[batch], None, None);
        assert_eq!(summary.particle_count, 3);
        assert_eq!(summary.cpu_render_instance_count, 0);
        assert_eq!(summary.gpu_render_instance_count, 3);
        assert_eq!(summary.alpha_count, 3);
        assert_eq!(summary.textured_count, 3);
        assert_eq!(summary.unique_texture_count, 1);
        assert_eq!(summary.batch_count, 1);
        assert_eq!(summary.cpu_batch_count, 0);
        assert_eq!(summary.gpu_batch_count, 1);
        assert_eq!(summary.source_particle_count, 1);
        assert_eq!(summary.submitted_source_particle_count, 1);
        assert!(!summary.bounds.is_empty);
    }

    #[test]
    fn deformable_mesh_derives_topology_and_normals() {
        let positions = vec![
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
        ];
        let indices = vec![0u32, 1, 2];
        let mesh = RenderDeformableMesh::with_geometry(
            EntityID::new(0, 0),
            1,
            None,
            positions,
            indices.clone(),
            Vec::new(),
            None,
        );
        assert_eq!(mesh.texture_coordinates.len(), 3);
        assert_eq!(
            mesh.topology_revision,
            RenderDeformableMesh::stable_topology_revision(&indices)
        );
        assert_eq!(mesh.vertex_count(), 3);
        assert_eq!(mesh.triangle_count(), 1);
        assert!(mesh.is_valid());
        assert_eq!(mesh.normals[0], Float3::new(0.0, 0.0, 1.0));
    }

    #[test]
    fn scene_sorts_deformable_meshes_and_derives_summary() {
        let low = EntityID::new(1, 0);
        let high = EntityID::new(2, 0);
        let scene = RenderScene::new(
            RenderCamera::fallback(),
            Vec::new(),
            Vec::new(),
            RenderEnvironment::fallback(),
            vec![
                RenderDeformableMesh::new(high, 1),
                RenderDeformableMesh::new(low, 1),
            ],
            vec![test_particle(None)],
            Vec::new(),
            None,
        );
        assert_eq!(scene.deformable_meshes[0].entity, low);
        assert_eq!(scene.deformable_meshes[1].entity, high);
        assert_eq!(scene.particle_summary.particle_count, 1);
        assert!(scene.geometry_overlays.is_empty());
    }
}
