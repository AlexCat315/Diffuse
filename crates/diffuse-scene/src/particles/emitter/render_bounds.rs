//! Conservative render bounds and render LOD/culling budgets.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/RenderBounds.swift`.

// Swift's `!(a > b)` predicates also reject NaN. Keep the negated form instead
// of rewriting to `a <= b`, which would change behaviour on NaN inputs.
#![allow(clippy::neg_cmp_op_on_partial_ord)]

use diffuse_math::simd::simd_compat::{Float3, simd_clamp_scalar, simd_length};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::particles::particle_events::ParticleSubEmitter;
use crate::particles::particle_types::{
    ParticleEmissionShape, ParticleForceMode, ParticleRenderAlignment, ParticleRenderBoundsMode,
};

impl ParticleEmitter {
    pub fn effective_render_bounds_radius(&self) -> f32 {
        match self.settings.renderer.render_bounds_mode {
            ParticleRenderBoundsMode::Disabled => 0.0,
            ParticleRenderBoundsMode::Manual => swift_max_f32(0.0, self.settings.renderer.render_bounds_radius),
            ParticleRenderBoundsMode::Automatic => self.estimated_render_bounds_radius(),
        }
    }

    pub fn render_lod_scale(&self, camera_distance: f32) -> f32 {
        let renderer = &self.settings.renderer;
        if !(renderer.render_lod_end_distance > renderer.render_lod_start_distance) {
            return 1.0;
        }
        let t = simd_clamp_scalar(
            (swift_max_f32(0.0, camera_distance) - renderer.render_lod_start_distance)
                / (renderer.render_lod_end_distance - renderer.render_lod_start_distance),
            0.0,
            1.0,
        );
        1.0 + (renderer.render_lod_min_particle_scale - 1.0) * t
    }

    pub fn effective_max_rendered_particles(
        &self,
        camera_distance: f32,
        live_particle_count: i64,
    ) -> i64 {
        let live_count = live_particle_count.max(0);
        if live_count <= 0 {
            return 0;
        }
        let base_limit = if self.settings.emission.max_rendered_particles > 0 {
            self.settings.emission.max_rendered_particles.min(live_count)
        } else {
            live_count
        };
        let scale = self.render_lod_scale(camera_distance);
        if !(scale > 0.0) {
            return 0;
        }
        base_limit.min(1.max((base_limit as f32 * scale).ceil() as i64))
    }

    pub fn estimated_render_bounds_radius(&self) -> f32 {
        let primary_lifetime = swift_max_f32(
            0.0001,
            self.settings.appearance.lifetime + self.settings.appearance.lifetime_randomness,
        );
        let spawn_extent = self.estimated_spawn_extent();
        let primary_velocity = estimated_velocity_magnitude(
            self.settings.velocity.start_velocity,
            self.settings.velocity.velocity_randomness,
        );
        let acceleration = self.estimated_acceleration_magnitude();
        let primary_travel = estimated_travel_distance(
            primary_lifetime,
            primary_velocity,
            acceleration,
        );
        let child_travel = self.estimated_sub_emitter_expansion(acceleration);
        let billboard_radius =
            self.estimated_billboard_radius(swift_max_f32(primary_velocity, child_travel.velocity));
        let force_extent: f32 = if self.settings.forces.force_mode != ParticleForceMode::None
            && self.settings.forces.force_radius > 0.0
        {
            simd_length(self.settings.forces.force_center) + self.settings.forces.force_radius
        } else {
            0.0
        };
        let radius = spawn_extent
            + primary_travel
            + child_travel.distance
            + billboard_radius
            + force_extent;
        if radius.is_finite() {
            swift_max_f32(0.0, radius)
        } else {
            swift_max_f32(0.0, self.settings.renderer.render_bounds_radius)
        }
    }

    fn estimated_spawn_extent(&self) -> f32 {
        match self.settings.shape.emission_shape {
            ParticleEmissionShape::Sphere => self.settings.shape.spawn_radius,
            ParticleEmissionShape::Box => simd_length(self.settings.shape.box_half_extents),
            ParticleEmissionShape::Cone => (self.settings.shape.cone_radius
                * self.settings.shape.cone_radius
                + self.settings.shape.cone_height * self.settings.shape.cone_height)
                .sqrt(),
        }
    }

    fn estimated_acceleration_magnitude(&self) -> f32 {
        simd_length(self.settings.forces.gravity)
            + self.settings.forces.noise_strength
            + self.settings.forces.force_strength.abs()
            + self.settings.forces.vector_field_strength.abs()
    }

    fn estimated_sub_emitter_expansion(
        &self,
        acceleration_magnitude: f32,
    ) -> SubEmitterExpansion {
        let mut max_distance: f32 = 0.0;
        let mut max_velocity: f32 = 0.0;
        if let Some(legacy_rule) = self.legacy_sub_emitter_rule() {
            accumulate_sub_emitter_expansion(
                &mut max_distance,
                &mut max_velocity,
                &legacy_rule,
                acceleration_magnitude,
            );
        }
        for rule in &self.settings.sub_emitters.rules {
            accumulate_sub_emitter_expansion(
                &mut max_distance,
                &mut max_velocity,
                rule,
                acceleration_magnitude,
            );
        }
        SubEmitterExpansion {
            distance: max_distance,
            velocity: max_velocity,
        }
    }

    fn estimated_billboard_radius(&self, velocity_magnitude: f32) -> f32 {
        let settings = &self.settings;
        let mut size = estimated_maximum_particle_size(
            settings,
            settings.appearance.start_size,
            settings.appearance.end_size,
        );
        size = swift_max_f32(
            size,
            estimated_maximum_particle_size(
                settings,
                settings.sub_emitters.legacy_start_size,
                settings.sub_emitters.legacy_end_size,
            ),
        );
        for rule in &settings.sub_emitters.rules {
            size = swift_max_f32(
                size,
                estimated_maximum_particle_size(settings, rule.start_size, rule.end_size),
            );
        }
        let size_scale = swift_max_f32(0.0, 1.0 + settings.appearance.size_randomness);
        let stretch = if settings.renderer.render_alignment == ParticleRenderAlignment::Velocity {
            swift_min_f32(
                settings.renderer.velocity_stretch_max,
                swift_max_f32(
                    1.0,
                    1.0 + velocity_magnitude * settings.renderer.velocity_stretch_scale,
                ),
            )
        } else {
            1.0
        };
        let billboard_radius =
            swift_max_f32(0.0, size) * size_scale * swift_max_f32(1.0, stretch)
                * std::f32::consts::FRAC_1_SQRT_2;
        let trail_radius = if settings.trails.trail_length > 0.0 {
            velocity_magnitude * settings.trails.trail_length
        } else {
            0.0
        };
        billboard_radius + trail_radius
    }
}

/// `(distance:velocity:)` from `estimatedSubEmitterExpansion`.
struct SubEmitterExpansion {
    distance: f32,
    velocity: f32,
}

fn estimated_velocity_magnitude(start_velocity: Float3, randomness: Float3) -> f32 {
    simd_length(start_velocity) + simd_length(randomness)
}

fn estimated_travel_distance(
    lifetime: f32,
    velocity_magnitude: f32,
    acceleration_magnitude: f32,
) -> f32 {
    velocity_magnitude * lifetime + 0.5 * acceleration_magnitude * lifetime * lifetime
}

fn estimated_maximum_particle_size(
    settings: &ParticleEmitterSettings,
    start_size: f32,
    end_size: f32,
) -> f32 {
    let (range_min, range_max) = settings.appearance.size_curve.conservative_value_range();
    let delta = end_size - start_size;
    swift_max_f32(
        swift_max_f32(0.0, start_size + delta * range_min),
        start_size + delta * range_max,
    )
}

fn accumulate_sub_emitter_expansion(
    max_distance: &mut f32,
    max_velocity: &mut f32,
    rule: &ParticleSubEmitter,
    acceleration_magnitude: f32,
) {
    let velocity = estimated_velocity_magnitude(rule.start_velocity, rule.velocity_randomness);
    let travel =
        estimated_travel_distance(rule.lifetime, velocity, acceleration_magnitude);
    let depth = 1.max(rule.max_depth) as f32;
    *max_distance = swift_max_f32(*max_distance, travel * depth);
    *max_velocity = swift_max_f32(*max_velocity, velocity);
}

/// Swift's `max(_:_:)` is `y >= x ? y : x`, so a NaN first operand survives.
#[inline]
fn swift_max_f32(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}

/// Swift's `min(_:_:)` is `y < x ? y : x`.
#[inline]
fn swift_min_f32(x: f32, y: f32) -> f32 {
    if y < x { y } else { x }
}
