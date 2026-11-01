//! Spawning: the per-frame spawn budget, per-particle sampling, sub-emitters and
//! distance-based emission.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/Spawning.swift`.
//! Every RNG draw happens in the same order as the Swift original; the sampling
//! order is part of the recorded simulation baseline.

// Swift's `!(a > b)` predicates also reject NaN. Keep the negated form instead
// of rewriting to `a <= b`, which would change behaviour on NaN inputs.
#![allow(clippy::neg_cmp_op_on_partial_ord)]

use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_clamp_scalar, simd_inverse,
    simd_length,
};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_events::ParticleSubEmitter;
use crate::particles::particle_types::{Particle, ParticleSimulationSpace, ParticleSubEmitterTrigger};

/// What a spawn request asked for and what it managed to produce.
pub(crate) struct ParticleSpawnResult {
    pub requested: i64,
    pub spawned: i64,
    pub capacity_limited_count: i64,
    pub spawn_budget_limited_count: i64,
}

impl ParticleSpawnResult {
    pub fn new(requested: i64, spawned: i64) -> Self {
        ParticleSpawnResult {
            requested,
            spawned,
            capacity_limited_count: 0,
            spawn_budget_limited_count: 0,
        }
    }

    pub fn with_counts(
        requested: i64,
        spawned: i64,
        capacity_limited_count: i64,
        spawn_budget_limited_count: i64,
    ) -> Self {
        ParticleSpawnResult {
            requested,
            spawned,
            capacity_limited_count,
            spawn_budget_limited_count,
        }
    }

    pub fn include(&mut self, other: &ParticleSpawnResult) {
        self.requested += other.requested;
        self.spawned += other.spawned;
        self.capacity_limited_count += other.capacity_limited_count;
        self.spawn_budget_limited_count += other.spawn_budget_limited_count;
    }
}

/// A per-frame allowance of new particles. A zero `limit` means "unlimited".
pub(crate) struct ParticleSpawnBudget {
    remaining: Option<i64>,
    pub consumed_count: i64,
}

impl ParticleSpawnBudget {
    pub fn new(limit: i64) -> Self {
        ParticleSpawnBudget {
            remaining: if limit > 0 { Some(limit) } else { None },
            consumed_count: 0,
        }
    }

    /// Returns `(granted, rejected)`.
    pub fn grant(&mut self, requested: i64) -> (i64, i64) {
        let requested = requested.max(0);
        if requested <= 0 {
            return (0, 0);
        }
        let Some(current) = self.remaining else {
            self.consumed_count += requested;
            return (requested, 0);
        };
        let granted = requested.min(current.max(0));
        self.remaining = Some((current - granted).max(0));
        self.consumed_count += granted;
        (granted, requested - granted)
    }
}

/// One sampled spawn, before it is turned into a `Particle`.
struct ParticleSpawnSample {
    offset: Float3,
    velocity_jitter: Float3,
    lifetime: f32,
    size_scale: f32,
    rotation: f32,
    angular_velocity: f32,
    texture_frame_seed: u16,
}

impl ParticleEmitter {
    // MARK: - Spawning

    /// The budgeted spawn.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn spawn_with_budget(
        &mut self,
        count: i64,
        world_transform: Option<Float4x4>,
        world_origin_override: Option<Float3>,
        inherited_world_velocity: Float3,
        max_live_particles: Option<i64>,
        record_spawned: bool,
        budget: &mut ParticleSpawnBudget,
    ) -> ParticleSpawnResult {
        let requested = count.max(0);
        if requested <= 0 || self.settings.emission.max_particles <= 0 {
            return ParticleSpawnResult::with_counts(requested, 0, requested, 0);
        }
        let budget_grant = budget.grant(requested);
        let live_limit = self.settings.emission.max_particles.min(
            max_live_particles
                .unwrap_or(self.settings.emission.max_particles)
                .max(0),
        );
        let room = live_limit - self.runtime.particles.len() as i64;
        let n = budget_grant.0.min(room.max(0));
        for _ in 0..n {
            let sample = self.make_spawn_sample();
            let local_position = self.settings.shape.origin_offset + sample.offset;
            let local_velocity = self.settings.velocity.start_velocity + sample.velocity_jitter;
            let spawn_transform = world_transform.unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
            let inherited_velocity =
                self.inherited_spawn_velocity(inherited_world_velocity, spawn_transform);
            let (position, velocity) = match self.settings.gpu_simulation.simulation_space {
                ParticleSimulationSpace::Local => {
                    (local_position, local_velocity + inherited_velocity)
                }
                ParticleSimulationSpace::World => {
                    let position = match world_origin_override {
                        Some(origin) => origin + transform_direction(sample.offset, &spawn_transform),
                        None => transform_point(local_position, &spawn_transform),
                    };
                    let velocity =
                        transform_direction(local_velocity, &spawn_transform) + inherited_velocity;
                    (position, velocity)
                }
            };
            let mut p = Particle {
                position,
                velocity,
                age: 0.0,
                lifetime: sample.lifetime,
                size_scale: sample.size_scale,
                rotation: sample.rotation,
                angular_velocity: sample.angular_velocity,
                size: 1.0,
                color: Float4::new(1.0, 1.0, 1.0, 1.0),
                generation: 0,
                appearance_index: 0,
                texture_frame_seed: sample.texture_frame_seed,
            };
            self.refresh_appearance(&mut p);
            self.runtime.particles.push(p);
            if record_spawned {
                self.runtime.last_frame_spawned_particles.push(p);
            }
        }
        ParticleSpawnResult::with_counts(
            requested,
            n,
            budget_grant.0 - n,
            budget_grant.1,
        )
    }

    /// The unbudgeted spawn: `ParticleSpawnBudget(limit: 0)` grants everything.
    pub(crate) fn spawn(
        &mut self,
        count: i64,
        world_transform: Option<Float4x4>,
        world_origin_override: Option<Float3>,
        inherited_world_velocity: Float3,
        max_live_particles: Option<i64>,
        record_spawned: bool,
    ) -> ParticleSpawnResult {
        let mut budget = ParticleSpawnBudget::new(0);
        self.spawn_with_budget(
            count,
            world_transform,
            world_origin_override,
            inherited_world_velocity,
            max_live_particles,
            record_spawned,
            &mut budget,
        )
    }

    fn make_spawn_sample(&mut self) -> ParticleSpawnSample {
        let offset = self.spawn_offset();
        let jitter = Float3::new(
            self.next_signed() * self.settings.velocity.velocity_randomness.x,
            self.next_signed() * self.settings.velocity.velocity_randomness.y,
            self.next_signed() * self.settings.velocity.velocity_randomness.z,
        );
        ParticleSpawnSample {
            offset,
            velocity_jitter: jitter,
            lifetime: swift_max_f32(
                0.0001,
                self.settings.appearance.lifetime
                    + self.next_signed() * self.settings.appearance.lifetime_randomness,
            ),
            size_scale: swift_max_f32(
                0.0,
                1.0 + self.next_signed() * self.settings.appearance.size_randomness,
            ),
            rotation: self.settings.appearance.start_rotation
                + self.next_signed() * self.settings.appearance.rotation_randomness,
            angular_velocity: self.settings.appearance.angular_velocity
                + self.next_signed() * self.settings.appearance.angular_velocity_randomness,
            texture_frame_seed: self.texture_frame_seed_snapshot(),
        }
    }

    pub(crate) fn spawn_sub_emitter_particles(
        &mut self,
        trigger: ParticleSubEmitterTrigger,
        source: &Particle,
        survivors_count: i64,
        pending: &mut Vec<Particle>,
        budget: &mut ParticleSpawnBudget,
    ) -> ParticleSpawnResult {
        if self.settings.emission.max_particles <= 0 {
            return ParticleSpawnResult::new(0, 0);
        }
        let mut result = ParticleSpawnResult::new(0, 0);
        if let Some(legacy) = self.legacy_sub_emitter_rule()
            && legacy.trigger == trigger
        {
            let legacy_result = self.spawn_sub_emitter_particles_for_rule(
                &legacy,
                1,
                source,
                survivors_count,
                pending,
                budget,
            );
            result.include(&legacy_result);
        }
        let rules = self.settings.sub_emitters.rules.clone();
        for (index, rule) in rules.iter().enumerate() {
            if rule.trigger != trigger {
                continue;
            }
            let rule_result = self.spawn_sub_emitter_particles_for_rule(
                rule,
                clamping_u16(index as i64 + 2),
                source,
                survivors_count,
                pending,
                budget,
            );
            result.include(&rule_result);
        }
        result
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn spawn_sub_emitter_particles_for_rule(
        &mut self,
        rule: &ParticleSubEmitter,
        appearance_index: u16,
        source: &Particle,
        survivors_count: i64,
        pending: &mut Vec<Particle>,
        budget: &mut ParticleSpawnBudget,
    ) -> ParticleSpawnResult {
        if !rule.is_active() || !(source.generation < clamping_u8(rule.max_depth)) {
            return ParticleSpawnResult::new(0, 0);
        }
        if rule.probability < 1.0 && self.next_unit() > rule.probability {
            return ParticleSpawnResult::new(0, 0);
        }

        let room = self.settings.emission.max_particles - survivors_count - pending.len() as i64;
        if room <= 0 {
            return ParticleSpawnResult::with_counts(rule.burst_count, 0, rule.burst_count, 0);
        }
        let budget_grant = budget.grant(rule.burst_count);
        let count = budget_grant.0.min(room);
        let child_generation = if source.generation == u8::MAX {
            u8::MAX
        } else {
            source.generation + 1
        };
        for _ in 0..count {
            let jitter = Float3::new(
                self.next_signed() * rule.velocity_randomness.x,
                self.next_signed() * rule.velocity_randomness.y,
                self.next_signed() * rule.velocity_randomness.z,
            );
            let mut child = Particle {
                position: source.position,
                velocity: rule.start_velocity
                    + jitter
                    + source.velocity * rule.inherit_velocity,
                age: 0.0,
                lifetime: rule.lifetime,
                size_scale: 1.0,
                rotation: self.settings.appearance.start_rotation
                    + self.next_signed() * self.settings.appearance.rotation_randomness,
                angular_velocity: self.settings.appearance.angular_velocity
                    + self.next_signed() * self.settings.appearance.angular_velocity_randomness,
                size: 1.0,
                color: Float4::new(1.0, 1.0, 1.0, 1.0),
                generation: child_generation,
                appearance_index,
                texture_frame_seed: self.texture_frame_seed_snapshot(),
            };
            self.refresh_appearance(&mut child);
            pending.push(child);
        }
        ParticleSpawnResult::with_counts(
            rule.burst_count,
            count,
            budget_grant.0 - count,
            budget_grant.1,
        )
    }

    pub(crate) fn append_event_particles(
        &mut self,
        event_particles: Vec<Particle>,
    ) -> ParticleSpawnResult {
        if event_particles.is_empty() {
            return ParticleSpawnResult::new(0, 0);
        }
        let room = self.settings.emission.max_particles - self.runtime.particles.len() as i64;
        if room <= 0 {
            let count = event_particles.len() as i64;
            return ParticleSpawnResult::with_counts(count, 0, count, 0);
        }
        let to_append = (event_particles.len() as i64).min(room) as usize;
        self.runtime
            .particles
            .extend_from_slice(&event_particles[..to_append]);
        self.runtime
            .last_frame_spawned_particles
            .extend_from_slice(&event_particles[..to_append]);
        ParticleSpawnResult::with_counts(
            event_particles.len() as i64,
            to_append as i64,
            event_particles.len() as i64 - to_append as i64,
            0,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn spawn_distance_emission(
        &mut self,
        from: Option<Float3>,
        to: Float3,
        world_transform: Option<Float4x4>,
        inherited_world_velocity: Float3,
        rate_multiplier: f32,
        max_live_particles: Option<i64>,
        budget: &mut ParticleSpawnBudget,
    ) -> ParticleSpawnResult {
        // Swift's `defer` runs on every return path, including the early exits.
        let result = self.spawn_distance_emission_inner(
            from,
            to,
            world_transform,
            inherited_world_velocity,
            rate_multiplier,
            max_live_particles,
            budget,
        );
        self.runtime.previous_emitter_position = Some(to);
        result
    }

    #[allow(clippy::too_many_arguments)]
    fn spawn_distance_emission_inner(
        &mut self,
        from: Option<Float3>,
        current: Float3,
        world_transform: Option<Float4x4>,
        inherited_world_velocity: Float3,
        rate_multiplier: f32,
        max_live_particles: Option<i64>,
        budget: &mut ParticleSpawnBudget,
    ) -> ParticleSpawnResult {
        let Some(previous) = from else {
            return ParticleSpawnResult::new(0, 0);
        };
        if !(self.settings.emission.distance_emission_rate > 0.0) || !(rate_multiplier > 0.0) {
            return ParticleSpawnResult::new(0, 0);
        }
        let delta = current - previous;
        let distance = simd_length(delta);
        if !(distance > 0.0001) {
            return ParticleSpawnResult::new(0, 0);
        }

        self.runtime.distance_emission_accumulator += distance
            * self.settings.emission.distance_emission_rate
            * rate_multiplier;
        let to_spawn = self.runtime.distance_emission_accumulator as i64;
        if to_spawn <= 0 {
            return ParticleSpawnResult::new(0, 0);
        }
        self.runtime.distance_emission_accumulator -= to_spawn as f32;

        match self.settings.gpu_simulation.simulation_space {
            ParticleSimulationSpace::Local => self.spawn_with_budget(
                to_spawn,
                world_transform,
                None,
                inherited_world_velocity,
                max_live_particles,
                true,
                budget,
            ),
            ParticleSimulationSpace::World => {
                let budget_grant = budget.grant(to_spawn);
                let live_limit = self.settings.emission.max_particles.min(
                    max_live_particles
                        .unwrap_or(self.settings.emission.max_particles)
                        .max(0),
                );
                let accepted =
                    budget_grant.0.min((live_limit - self.runtime.particles.len() as i64).max(0));
                let mut result = ParticleSpawnResult::with_counts(
                    to_spawn,
                    0,
                    budget_grant.0 - accepted,
                    budget_grant.1,
                );
                let mut unrestricted_budget = ParticleSpawnBudget::new(0);
                for index in 0..accepted {
                    let t = (index as f32 + 0.5) / accepted.max(1) as f32;
                    let world_origin = previous + delta * t;
                    let spawn_result = self.spawn_with_budget(
                        1,
                        world_transform,
                        Some(world_origin),
                        inherited_world_velocity,
                        max_live_particles,
                        true,
                        &mut unrestricted_budget,
                    );
                    result.spawned += spawn_result.spawned;
                    result.capacity_limited_count += spawn_result.capacity_limited_count;
                    result.spawn_budget_limited_count += spawn_result.spawn_budget_limited_count;
                }
                result
            }
        }
    }

    pub(crate) fn inherited_emitter_velocity(
        &self,
        from: Option<Float3>,
        to: Float3,
        delta_time: f32,
    ) -> Float3 {
        if !(self.settings.velocity.velocity_inheritance > 0.0) {
            return Float3::ZERO;
        }
        let Some(previous) = from else {
            return Float3::ZERO;
        };
        if !(delta_time > 0.0001) {
            return Float3::ZERO;
        }
        (to - previous) / delta_time
    }

    fn inherited_spawn_velocity(
        &self,
        world_velocity: Float3,
        spawn_transform: Float4x4,
    ) -> Float3 {
        if !(self.settings.velocity.velocity_inheritance > 0.0) {
            return Float3::ZERO;
        }
        match self.settings.gpu_simulation.simulation_space {
            ParticleSimulationSpace::Local => {
                transform_direction(world_velocity, &simd_inverse(spawn_transform))
                    * self.settings.velocity.velocity_inheritance
            }
            ParticleSimulationSpace::World => {
                world_velocity * self.settings.velocity.velocity_inheritance
            }
        }
    }

    pub(crate) fn distance_emitter_position(&self, world_transform: Option<Float4x4>) -> Float3 {
        transform_point(
            self.settings.shape.origin_offset,
            &world_transform.unwrap_or(MATRIX_IDENTITY_FLOAT4X4),
        )
    }

    /// The deprecated single-rule sub-emitter, materialized on demand.
    pub(crate) fn legacy_sub_emitter_rule(&self) -> Option<ParticleSubEmitter> {
        let sub_emitters = &self.settings.sub_emitters;
        if sub_emitters.legacy_trigger == ParticleSubEmitterTrigger::None
            || sub_emitters.legacy_burst_count <= 0
        {
            return None;
        }
        Some(ParticleSubEmitter {
            trigger: sub_emitters.legacy_trigger,
            burst_count: sub_emitters.legacy_burst_count.max(0),
            probability: simd_clamp_scalar(sub_emitters.legacy_probability, 0.0, 1.0),
            max_depth: sub_emitters.legacy_max_depth.max(0),
            inherit_velocity: swift_max_f32(0.0, sub_emitters.legacy_inherit_velocity),
            lifetime: swift_max_f32(0.0001, sub_emitters.legacy_lifetime),
            start_velocity: sub_emitters.legacy_start_velocity,
            velocity_randomness: sub_emitters.legacy_velocity_randomness,
            start_size: swift_max_f32(0.0, sub_emitters.legacy_start_size),
            end_size: swift_max_f32(0.0, sub_emitters.legacy_end_size),
            start_color: sub_emitters.legacy_start_color,
            end_color: sub_emitters.legacy_end_color,
        })
    }
}

pub(crate) fn transform_point(point: Float3, matrix: &Float4x4) -> Float3 {
    let transformed = *matrix * Float4::new(point.x, point.y, point.z, 1.0);
    if transformed.w.abs() > 0.0001 {
        return Float3::new(
            transformed.x / transformed.w,
            transformed.y / transformed.w,
            transformed.z / transformed.w,
        );
    }
    Float3::new(transformed.x, transformed.y, transformed.z)
}

pub(crate) fn transform_direction(direction: Float3, matrix: &Float4x4) -> Float3 {
    let transformed = *matrix * Float4::new(direction.x, direction.y, direction.z, 0.0);
    Float3::new(transformed.x, transformed.y, transformed.z)
}

/// `UInt8(clamping:)`.
fn clamping_u8(value: i64) -> u8 {
    if value < 0 {
        0
    } else if value > u8::MAX as i64 {
        u8::MAX
    } else {
        value as u8
    }
}

/// `UInt16(clamping:)`.
fn clamping_u16(value: i64) -> u16 {
    if value < 0 {
        0
    } else if value > u16::MAX as i64 {
        u16::MAX
    } else {
        value as u16
    }
}

/// Swift's `max(_:_:)` is `y >= x ? y : x`, so a NaN first operand survives.
#[inline]
fn swift_max_f32(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}
