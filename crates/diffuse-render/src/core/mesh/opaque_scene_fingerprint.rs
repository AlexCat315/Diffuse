//! Content hash of the opaque scene inputs.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Mesh/OpaqueSceneFingerprint.swift`.
//!
//! Swift uses `Hasher`, whose per-process seed is constant within one run —
//! exactly what the frame-to-frame comparison needs, but Swift never exposes a
//! stable algorithm. The Rust port uses a fixed FNV-style accumulator (same
//! shape as `diffuse_scene`'s `PhysicsStateHasher`): deterministic across runs,
//! order-independent over collections through wrapping sums, and equally valid
//! for the "equal hashes mean identical image" contract.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float4x4;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_scene::{RenderInstance, RenderLight, RenderMaterial};

use crate::core::frame::render_packet::RenderPacket;

/// One accumulator matching Swift's `Hasher` role. The constants are local to
/// this fingerprint (not a cross-crate parity contract).
struct SceneHasher {
    hash: u64,
}

impl SceneHasher {
    fn new() -> Self {
        SceneHasher {
            hash: 1_469_598_103_934_665_603,
        }
    }

    #[inline]
    fn combine_u64(&mut self, value: u64) {
        for byte in value.to_le_bytes() {
            self.hash ^= u64::from(byte);
            self.hash = self.hash.wrapping_mul(1_099_511_628_211);
        }
    }

    #[inline]
    fn combine_i64(&mut self, value: i64) {
        self.combine_u64(value as u64);
    }

    /// `combine(Float)` — the raw bit pattern keeps `-0.0`/NaN distinctions.
    #[inline]
    fn combine_f32(&mut self, value: f32) {
        self.combine_u64(u64::from(value.to_bits()));
    }

    #[inline]
    fn combine_f64(&mut self, value: f64) {
        self.combine_u64(value.to_bits());
    }

    #[inline]
    fn combine_bool(&mut self, value: bool) {
        self.combine_u64(u64::from(value));
    }

    #[inline]
    fn combine_option_u64(&mut self, value: Option<u64>) {
        match value {
            Some(inner) => {
                self.combine_bool(true);
                self.combine_u64(inner);
            }
            None => self.combine_bool(false),
        }
    }

    #[inline]
    fn combine_option_i64(&mut self, value: Option<i64>) {
        match value {
            Some(inner) => {
                self.combine_bool(true);
                self.combine_i64(inner);
            }
            None => self.combine_bool(false),
        }
    }

    #[inline]
    fn combine_string(&mut self, value: &str) {
        for byte in value.as_bytes() {
            self.combine_u64(u64::from(*byte));
        }
    }

    fn combine_float3(&mut self, value: diffuse_math::simd::simd_compat::Float3) {
        self.combine_f32(value.x);
        self.combine_f32(value.y);
        self.combine_f32(value.z);
    }

    fn combine_float4(&mut self, value: diffuse_math::simd::simd_compat::Float4) {
        self.combine_f32(value.x);
        self.combine_f32(value.y);
        self.combine_f32(value.z);
        self.combine_f32(value.w);
    }

    /// Swift's `Self.combine(&hasher, matrix)`.
    fn combine_matrix(&mut self, matrix: &Float4x4) {
        for column in &matrix.columns {
            self.combine_float4(*column);
        }
    }

    #[inline]
    fn finalize(self) -> i64 {
        self.hash as i64
    }
}

/// `OpaqueSceneFingerprint` — the free-function namespace.
pub enum OpaqueSceneFingerprint {}

impl OpaqueSceneFingerprint {
    /// Content hash of everything that determines the opaque render — camera,
    /// instances, lights, environment, render settings and skinning poses — but
    /// NOT the transparent particles. Equal hashes on consecutive frames mean
    /// the lit-opaque image is identical and can be served from
    /// `opaqueSnapshotTarget` instead of re-rendering every opaque pass.
    ///
    /// Collections are folded with wrapping sums so the hash is independent of
    /// array / dictionary iteration order (extraction order is not guaranteed
    /// stable).
    pub fn make(packet: &RenderPacket, settings_generation: u64) -> i64 {
        let mut hasher = SceneHasher::new();

        let camera = &packet.scene.camera;
        hasher.combine_float3(camera.eye);
        hasher.combine_float3(camera.target);
        hasher.combine_float3(camera.up);
        hasher.combine_f32(camera.fov_y_radians);
        hasher.combine_string(camera.projection.raw_value());
        hasher.combine_f32(camera.orthographic_height);
        hasher.combine_f32(camera.near);
        hasher.combine_f32(camera.far);
        hasher.combine_u64(u64::from(packet.drawable_size.width));
        hasher.combine_u64(u64::from(packet.drawable_size.height));

        // Render settings are summarised by a monotonic generation counter that
        // is bumped whenever the active settings change.
        hasher.combine_u64(settings_generation);

        let environment = &packet.scene.environment;
        hasher.combine_float3(environment.ambient_color);
        hasher.combine_f32(environment.ambient_intensity);
        hasher.combine_f32(environment.exposure);

        hasher.combine_u64(packet.scene.instances.len() as u64);
        let mut instance_accumulator: i64 = 0;
        for instance in &packet.scene.instances {
            instance_accumulator = instance_accumulator.wrapping_add(instance_hash(instance));
        }
        hasher.combine_i64(instance_accumulator);

        hasher.combine_u64(packet.scene.deformable_meshes.len() as u64);
        let mut deformable_accumulator: i64 = 0;
        for mesh in &packet.scene.deformable_meshes {
            let mut sub = SceneHasher::new();
            sub.combine_u64(mesh.entity.raw_value());
            sub.combine_u64(mesh.revision);
            sub.combine_u64(mesh.topology_revision);
            sub.combine_u64(mesh.vertex_count() as u64);
            sub.combine_u64(mesh.triangle_count() as u64);
            deformable_accumulator = deformable_accumulator.wrapping_add(sub.finalize());
        }
        hasher.combine_i64(deformable_accumulator);

        hasher.combine_u64(packet.scene.lights.len() as u64);
        let mut light_accumulator: i64 = 0;
        for light in &packet.scene.lights {
            light_accumulator = light_accumulator.wrapping_add(light_hash(light));
        }
        hasher.combine_i64(light_accumulator);

        hasher.combine_u64(packet.joint_palette_map.palettes.len() as u64);
        let mut joint_accumulator: i64 = 0;
        // `BTreeMap` iterates in entity order; Swift's iteration order was
        // arbitrary, which the wrapping sum already absorbs.
        let palettes: &BTreeMap<EntityID, diffuse_scene::media::animation::JointPalette> =
            &packet.joint_palette_map.palettes;
        for (entity, palette) in palettes {
            let mut sub = SceneHasher::new();
            sub.combine_u64(entity.raw_value());
            for matrix in &palette.matrices {
                sub.combine_matrix(matrix);
            }
            joint_accumulator = joint_accumulator.wrapping_add(sub.finalize());
        }
        hasher.combine_i64(joint_accumulator);

        hasher.finalize()
    }
}

fn instance_hash(instance: &RenderInstance) -> i64 {
    let mut hasher = SceneHasher::new();
    hasher.combine_option_u64(instance.entity.map(|entity| entity.raw_value()));
    hasher.combine_i64(instance.mesh.mesh_index);
    hasher.combine_option_string(instance.mesh.asset_id.as_deref());
    for lod in &instance.mesh.levels_of_detail {
        hasher.combine_i64(lod.mesh_index);
        hasher.combine_f32(lod.minimum_distance);
    }
    hasher.combine_matrix(&instance.transform);
    hasher.combine_float3(instance.color_tint);
    let material = &instance.material;
    combine_material(&mut hasher, material);
    hasher.finalize()
}

fn combine_material(hasher: &mut SceneHasher, material: &RenderMaterial) {
    hasher.combine_float4(material.base_color_factor);
    hasher.combine_option_i64(material.base_color_texture_index);
    hasher.combine_option_i64(material.normal_texture_index);
    hasher.combine_f32(material.metallic_factor);
    hasher.combine_f32(material.roughness_factor);
    hasher.combine_float3(material.emissive_factor);
    hasher.combine_option_string(material.alpha_mode.map(|mode| mode.raw_value()));
    hasher.combine_option_f32(material.alpha_cutoff);
    hasher.combine_option_bool(material.double_sided);
}

fn light_hash(light: &RenderLight) -> i64 {
    let mut hasher = SceneHasher::new();
    hasher.combine_string(light.type_.raw_value());
    hasher.combine_float3(light.position);
    hasher.combine_float3(light.direction);
    hasher.combine_float3(light.color);
    hasher.combine_f32(light.intensity);
    hasher.combine_f32(light.range);
    hasher.combine_f32(light.spot_inner_angle_radians);
    hasher.combine_f32(light.spot_outer_angle_radians);
    hasher.combine_bool(light.cast_shadows);
    hasher.combine_option_u64(light.entity.map(|entity| entity.raw_value()));
    hasher.finalize()
}

impl SceneHasher {
    fn combine_option_f32(&mut self, value: Option<f32>) {
        match value {
            Some(inner) => {
                self.combine_bool(true);
                self.combine_f32(inner);
            }
            None => self.combine_bool(false),
        }
    }

    fn combine_option_bool(&mut self, value: Option<bool>) {
        match value {
            Some(inner) => {
                self.combine_bool(true);
                self.combine_bool(inner);
            }
            None => self.combine_bool(false),
        }
    }

    fn combine_option_string(&mut self, value: Option<&str>) {
        match value {
            Some(inner) => {
                self.combine_bool(true);
                self.combine_string(inner);
            }
            None => self.combine_bool(false),
        }
    }
}
