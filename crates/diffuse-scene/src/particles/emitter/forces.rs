//! Per-particle force fields and plane collision.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/Forces.swift`.

use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_cross, simd_dot, simd_inverse,
    simd_length,
};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_types::{
    Particle, ParticleCollisionMode, ParticleForceMode, ParticleVectorFieldMode,
};

impl ParticleEmitter {
    pub(crate) fn noise_force(&self, position: Float3, age: f32) -> Float3 {
        if !(self.settings.forces.noise_strength > 0.0) {
            return Float3::ZERO;
        }
        let p = position * self.settings.forces.noise_scale;
        let phase = age * self.settings.forces.noise_speed
            + (self.settings.emission.seed & 0xFFFF) as f32 * 0.0001;
        Float3::new(
            sine_wave(p.x * 12.9898 + p.y * 78.233 + p.z * 37.719 + phase),
            sine_wave(p.y * 26.651 + p.z * 91.191 + p.x * 13.153 + phase + 2.17),
            sine_wave(p.z * 54.123 + p.x * 44.531 + p.y * 9.151 + phase + 4.31),
        ) * self.settings.forces.noise_strength
    }

    pub(crate) fn force_acceleration(&self, position: Float3) -> Float3 {
        if self.settings.forces.force_mode == ParticleForceMode::None
            || self.settings.forces.force_strength == 0.0
        {
            return Float3::ZERO;
        }

        let offset = position - self.settings.forces.force_center;
        let distance = simd_length(offset);
        if self.settings.forces.force_radius > 0.0
            && distance >= self.settings.forces.force_radius
        {
            return Float3::ZERO;
        }

        let attenuation: f32 = if self.settings.forces.force_radius > 0.0 {
            swift_max_f32(
                0.0,
                1.0 - distance / self.settings.forces.force_radius,
            )
            .powf(self.settings.forces.force_falloff)
        } else {
            1.0
        };
        if !(attenuation > 0.0) {
            return Float3::ZERO;
        }

        match self.settings.forces.force_mode {
            ParticleForceMode::None => Float3::ZERO,
            ParticleForceMode::Radial => {
                if !(distance > 0.0001) {
                    return Float3::ZERO;
                }
                (offset / distance) * self.settings.forces.force_strength * attenuation
            }
            ParticleForceMode::Vortex => {
                let axis = self.normalized_or_default(
                    self.settings.forces.force_axis,
                    Float3::new(0.0, 1.0, 0.0),
                );
                let planar = offset - axis * simd_dot(offset, axis);
                let planar_distance = simd_length(planar);
                if !(planar_distance > 0.0001) {
                    return Float3::ZERO;
                }
                let radial = planar / planar_distance;
                let tangent = self.normalized_or_default(
                    simd_cross(axis, radial),
                    Float3::new(0.0, 0.0, 1.0),
                );
                tangent * self.settings.forces.force_strength * attenuation
            }
        }
    }

    pub(crate) fn vector_field_acceleration(&self, position: Float3, age: f32) -> Float3 {
        if self.settings.forces.vector_field_mode == ParticleVectorFieldMode::None
            || self.settings.forces.vector_field_strength == 0.0
        {
            return Float3::ZERO;
        }
        match self.settings.forces.vector_field_mode {
            ParticleVectorFieldMode::None => Float3::ZERO,
            ParticleVectorFieldMode::Uniform => {
                self.normalized_or_default(
                    self.settings.forces.vector_field_direction,
                    Float3::new(0.0, 1.0, 0.0),
                ) * self.settings.forces.vector_field_strength
            }
            ParticleVectorFieldMode::Curl => {
                let p = position * self.settings.forces.vector_field_scale;
                let phase = age * self.settings.forces.vector_field_scroll_speed
                    + ((self.settings.emission.seed >> 16) & 0xFFFF) as f32 * 0.0001;
                let bias = self.normalized_or_default(
                    self.settings.forces.vector_field_direction,
                    Float3::new(0.0, 1.0, 0.0),
                );
                let field = Float3::new(
                    sine_wave(p.y * 8.173 + p.z * 3.117 + phase)
                        - sine_wave(p.z * 5.731 + p.x * 7.191 - phase),
                    sine_wave(p.z * 6.313 + p.x * 4.997 + phase + 1.37)
                        - sine_wave(p.x * 9.239 + p.y * 2.173 - phase),
                    sine_wave(p.x * 4.113 + p.y * 7.911 + phase + 2.71)
                        - sine_wave(p.y * 5.337 + p.z * 6.771 - phase),
                );
                let blended = field + bias * 0.25;
                self.normalized_or_default(blended, bias)
                    * self.settings.forces.vector_field_strength
            }
        }
    }

    pub(crate) fn make_collision_context(
        &self,
        world_transform: Option<Float4x4>,
    ) -> Option<ParticleCollisionContext> {
        if self.settings.collision.collision_mode != ParticleCollisionMode::WorldPlane {
            return None;
        }
        let to_world = world_transform.unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
        Some(ParticleCollisionContext {
            to_world,
            to_local: simd_inverse(to_world),
        })
    }

    pub(crate) fn apply_collision(
        &self,
        p: &mut Particle,
        context: Option<&ParticleCollisionContext>,
    ) -> bool {
        let collision = &self.settings.collision;
        match collision.collision_mode {
            ParticleCollisionMode::None => false,
            ParticleCollisionMode::LocalPlane => {
                if !(p.position.y < collision.collision_plane_y) {
                    return false;
                }
                p.position.y = collision.collision_plane_y;
                if !(p.velocity.y < 0.0) {
                    return false;
                }
                p.velocity.y = -p.velocity.y * collision.collision_restitution;
                let tangent_scale = 1.0 - collision.collision_damping;
                p.velocity.x *= tangent_scale;
                p.velocity.z *= tangent_scale;
                true
            }
            ParticleCollisionMode::WorldPlane => {
                let identity_context = ParticleCollisionContext {
                    to_world: MATRIX_IDENTITY_FLOAT4X4,
                    to_local: MATRIX_IDENTITY_FLOAT4X4,
                };
                let context = context.unwrap_or(&identity_context);
                let world_position4 = context.to_world
                    * Float4::new(p.position.x, p.position.y, p.position.z, 1.0);
                if !(world_position4.y < collision.collision_plane_y) {
                    return false;
                }

                let mut clamped_world_position = world_position4;
                clamped_world_position.y = collision.collision_plane_y;
                let local_position4 = context.to_local * clamped_world_position;
                if local_position4.w.abs() > 0.0001 {
                    p.position = Float3::new(
                        local_position4.x / local_position4.w,
                        local_position4.y / local_position4.w,
                        local_position4.z / local_position4.w,
                    );
                } else {
                    p.position = Float3::new(
                        local_position4.x,
                        local_position4.y,
                        local_position4.z,
                    );
                }

                let world_velocity4 = context.to_world
                    * Float4::new(p.velocity.x, p.velocity.y, p.velocity.z, 0.0);
                if !(world_velocity4.y < 0.0) {
                    return false;
                }

                let tangent_scale = 1.0 - collision.collision_damping;
                let bounced_world_velocity = Float4::new(
                    world_velocity4.x * tangent_scale,
                    -world_velocity4.y * collision.collision_restitution,
                    world_velocity4.z * tangent_scale,
                    0.0,
                );
                let local_velocity4 = context.to_local * bounced_world_velocity;
                p.velocity = Float3::new(
                    local_velocity4.x,
                    local_velocity4.y,
                    local_velocity4.z,
                );
                true
            }
        }
    }
}

/// `Float(sin(Double(x)))` — the Double hop is part of the value, not a rounding
/// accident, so it stays.
fn sine_wave(x: f32) -> f32 {
    (x as f64).sin() as f32
}

/// Swift's `max(_:_:)` is `y >= x ? y : x`, so a NaN first operand survives.
#[inline]
fn swift_max_f32(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}

/// The local/world transform pair a world-plane collision needs.
pub(crate) struct ParticleCollisionContext {
    pub to_world: Float4x4,
    pub to_local: Float4x4,
}
