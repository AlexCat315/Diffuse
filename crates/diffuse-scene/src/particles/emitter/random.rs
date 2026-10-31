//! Seeded spawn sampling: SplitMix64 plus emission-shape distributions.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/Random.swift`.
//! The bit operations are reproduced exactly; changing any constant or shift
//! invalidates every recorded particle baseline.

use diffuse_math::simd::simd_compat::{
    Float3, simd_cross, simd_length, simd_length_squared,
};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_types::ParticleEmissionShape;

impl ParticleEmitter {
    pub(crate) fn next_unit(&mut self) -> f32 {
        // SplitMix64 → [0, 1)
        self.runtime.rng_state = self.runtime.rng_state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.runtime.rng_state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 40) as f32 * (1.0 / 16_777_216.0)
    }

    pub(crate) fn next_signed(&mut self) -> f32 {
        self.next_unit() * 2.0 - 1.0
    }

    pub(crate) fn spawn_offset(&mut self) -> Float3 {
        match self.settings.shape.emission_shape {
            ParticleEmissionShape::Sphere => self.random_in_sphere() * self.settings.shape.spawn_radius,
            ParticleEmissionShape::Box => self.random_in_box(),
            ParticleEmissionShape::Cone => self.random_in_cone(),
        }
    }

    fn random_in_sphere(&mut self) -> Float3 {
        if !(self.settings.shape.spawn_radius > 0.0) {
            return Float3::ZERO;
        }
        // Rejection sampling keeps the distribution uniform inside the unit sphere.
        for _ in 0..8 {
            let v = Float3::new(self.next_signed(), self.next_signed(), self.next_signed());
            if simd_length_squared(v) <= 1.0 {
                return v;
            }
        }
        Float3::ZERO
    }

    fn random_in_box(&mut self) -> Float3 {
        Float3::new(
            self.next_signed() * self.settings.shape.box_half_extents.x,
            self.next_signed() * self.settings.shape.box_half_extents.y,
            self.next_signed() * self.settings.shape.box_half_extents.z,
        )
    }

    fn random_in_cone(&mut self) -> Float3 {
        if !(self.settings.shape.cone_radius > 0.0) || !(self.settings.shape.cone_height > 0.0) {
            return Float3::ZERO;
        }
        let axis = self.normalized_or_default(
            self.settings.velocity.start_velocity,
            Float3::new(0.0, 1.0, 0.0),
        );
        let basis = self.cone_basis(axis);
        let height = self.settings.shape.cone_height * self.next_unit().cbrt();
        let disk_radius = self.settings.shape.cone_radius
            * (height / self.settings.shape.cone_height)
            * self.next_unit().sqrt();
        let angle = self.next_unit() * 2.0 * core::f32::consts::PI;
        axis * height
            + basis.tangent * (angle.cos() * disk_radius)
            + basis.bitangent * (angle.sin() * disk_radius)
    }

    pub(crate) fn normalized_or_default(&self, v: Float3, fallback: Float3) -> Float3 {
        let len = simd_length(v);
        if !(len > 0.0001) {
            return fallback;
        }
        v / len
    }

    fn cone_basis(&self, axis: Float3) -> ConeBasis {
        let reference = if axis.y.abs() < 0.99 {
            Float3::new(0.0, 1.0, 0.0)
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let tangent = self.normalized_or_default(
            simd_cross(reference, axis),
            Float3::new(1.0, 0.0, 0.0),
        );
        let bitangent = self.normalized_or_default(
            simd_cross(axis, tangent),
            Float3::new(0.0, 0.0, 1.0),
        );
        ConeBasis { tangent, bitangent }
    }
}

/// Swift's labelled tuple return `(tangent:bitangent:)`.
struct ConeBasis {
    tangent: Float3,
    bitangent: Float3,
}
