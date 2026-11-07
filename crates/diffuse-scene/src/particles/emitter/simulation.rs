//! The CPU particle simulation step: integration, culling, continuous/burst/
//! distance spawning, sub-emitter events and prewarming.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/Simulation.swift`.
//!
//! The loop deliberately copies the live pool exactly like Swift's
//! `for var p in runtime.particles` — survivors are written back afterwards — so
//! spawns triggered by collision/death events see the same pool size they would
//! in Swift.

// Swift's `!(a > b)` predicates also reject NaN. Keep the negated form instead
// of rewriting to `a <= b`, which would change behaviour on NaN inputs.
#![allow(clippy::neg_cmp_op_on_partial_ord)]

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, simd_clamp_scalar};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::spawning::{ParticleSpawnBudget, ParticleSpawnResult};
use crate::particles::particle_curve::ParticleCurve;
use crate::particles::particle_events::ParticleEvent;
use crate::particles::particle_gpu_simulation_plan::ParticleGPUSimulationPlan;
use crate::particles::particle_stats::ParticleEmitterFrameStats;
use crate::particles::particle_types::{
    Particle, ParticleAdvanceOptions, ParticleSimulationSpace, ParticleSubEmitterTrigger,
};

impl ParticleEmitter {
    /// Number of currently-alive particles.
    pub fn alive_count(&self) -> i64 {
        self.runtime.particles.len() as i64
    }

    /// True while this emitter can still produce new particles from its authored
    /// emission controls. Non-looping emitters become inactive once `duration`
    /// is exhausted, even if `is_emitting` remains enabled for authoring.
    pub fn is_emission_active(&self) -> bool {
        if !self.settings.emission.is_emitting {
            return false;
        }
        if !(self.settings.emission.duration > 0.0) {
            return true;
        }
        self.settings.emission.looping || self.runtime.emitter_age < self.settings.emission.duration
    }

    pub fn reseed(&mut self, new_seed: u64) {
        self.settings.emission.seed = new_seed;
        self.runtime.rng_state = new_seed;
    }

    pub fn gpu_simulation_plan(&self) -> ParticleGPUSimulationPlan {
        ParticleGPUSimulationPlan::new(self)
    }

    /// Advances the simulation by `delta_time` seconds: integrates existing
    /// particles, culls expired ones, then spawns from the continuous emission
    /// rate and scheduled bursts (capped at `max_particles`).
    pub fn advance(
        &mut self,
        delta_time: f64,
        world_transform: Option<Float4x4>,
        options: &ParticleAdvanceOptions,
    ) {
        if !(delta_time > 0.0) {
            return;
        }
        self.run_prewarm_if_needed(world_transform, options);
        let scaled_delta_time =
            delta_time as f32 * swift_max_f32(0.0, self.settings.emission.simulation_speed);
        if !(scaled_delta_time > 0.0) {
            self.runtime.last_frame_spawned_particles.clear();
            self.runtime.last_frame_events.clear();
            self.runtime.previous_emitter_position =
                Some(self.distance_emitter_position(world_transform));
            self.runtime.last_frame_stats = ParticleEmitterFrameStats::new(
                0.0,
                self.runtime.particles.len() as i64,
                self.runtime.particles.len() as i64,
                self.settings.emission.max_particles,
                options.live_particle_limit(self.settings.emission.max_particles),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            );
            return;
        }
        self.advance_step(scaled_delta_time, world_transform, options);
    }

    fn advance_step(
        &mut self,
        dt: f32,
        world_transform: Option<Float4x4>,
        options: &ParticleAdvanceOptions,
    ) {
        if !(dt > 0.0) {
            return;
        }
        self.runtime.last_frame_spawned_particles.clear();
        self.runtime.last_frame_events.clear();
        let live_particle_limit = options.live_particle_limit(self.settings.emission.max_particles);
        let mut frame_stats = ParticleEmitterFrameStats::new(
            dt,
            self.runtime.particles.len() as i64,
            self.runtime.particles.len() as i64,
            self.settings.emission.max_particles,
            live_particle_limit,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            self.settings.emission.max_spawned_particles_per_frame,
            0,
            0,
            0,
        );
        let current_emitter_position = self.distance_emitter_position(world_transform);
        let inherited_world_velocity = self.inherited_emitter_velocity(
            self.runtime.previous_emitter_position,
            current_emitter_position,
            dt,
        );
        let collision_context =
            if self.settings.gpu_simulation.simulation_space == ParticleSimulationSpace::Local {
                self.make_collision_context(world_transform)
            } else {
                None
            };
        let defers_event_sub_emitters_to_external_simulation =
            self.has_event_sub_emitter_rules() && self.gpu_simulation_plan().uses_gpu();
        let mut spawn_budget =
            ParticleSpawnBudget::new(self.settings.emission.max_spawned_particles_per_frame);

        // Swift iterates a copy of the pool and assigns `survivors` afterwards.
        let particles = std::mem::take(&mut self.runtime.particles);
        let mut survivors: Vec<Particle> = Vec::with_capacity(particles.len());
        let mut event_particles: Vec<Particle> = Vec::new();
        let mut event_sub_emitter_spawn_result = ParticleSpawnResult::new(0, 0);
        for mut p in particles {
            p.velocity += self.settings.forces.gravity * dt;
            p.velocity += self.noise_force(p.position, p.age) * dt;
            p.velocity += self.force_acceleration(p.position) * dt;
            p.velocity += self.vector_field_acceleration(p.position, p.age) * dt;
            p.position += p.velocity * dt;
            p.rotation += p.angular_velocity * dt;
            let collided = self.apply_collision(&mut p, collision_context.as_ref());
            if collided {
                frame_stats.collision_count += 1;
                if !defers_event_sub_emitters_to_external_simulation {
                    self.record_event(ParticleSubEmitterTrigger::Collision, &p);
                    event_sub_emitter_spawn_result.include(&self.spawn_sub_emitter_particles(
                        ParticleSubEmitterTrigger::Collision,
                        &p,
                        survivors.len() as i64,
                        &mut event_particles,
                        &mut spawn_budget,
                    ));
                }
            }
            p.age += dt;
            if p.age < p.lifetime {
                self.refresh_appearance(&mut p);
                survivors.push(p);
            } else {
                frame_stats.expired_particle_count += 1;
                if !defers_event_sub_emitters_to_external_simulation {
                    self.record_event(ParticleSubEmitterTrigger::Death, &p);
                    event_sub_emitter_spawn_result.include(&self.spawn_sub_emitter_particles(
                        ParticleSubEmitterTrigger::Death,
                        &p,
                        survivors.len() as i64,
                        &mut event_particles,
                        &mut spawn_budget,
                    ));
                }
            }
        }
        self.runtime.particles = survivors;
        let event_spawn_result = self.append_event_particles(event_particles);
        frame_stats.requested_spawn_count += event_sub_emitter_spawn_result.requested;
        frame_stats.sub_emitter_spawned_count += event_spawn_result.spawned;
        frame_stats.capacity_limited_spawn_count += event_sub_emitter_spawn_result
            .capacity_limited_count
            + event_spawn_result.capacity_limited_count;
        frame_stats.spawn_budget_limited_count += event_sub_emitter_spawn_result
            .spawn_budget_limited_count
            + event_spawn_result.spawn_budget_limited_count;

        if !self.settings.emission.is_emitting {
            self.runtime.previous_emitter_position = Some(current_emitter_position);
            frame_stats.live_particle_count = self.runtime.particles.len() as i64;
            frame_stats.spawn_budget_consumed_count = spawn_budget.consumed_count;
            self.runtime.last_frame_stats = frame_stats;
            return;
        }
        let emission_step = self.active_emission_step(dt);
        if !(emission_step.delta > 0.0) {
            self.runtime.previous_emitter_position = Some(current_emitter_position);
            frame_stats.live_particle_count = self.runtime.particles.len() as i64;
            frame_stats.spawn_budget_consumed_count = spawn_budget.consumed_count;
            self.runtime.last_frame_stats = frame_stats;
            return;
        }
        let emission_rate_multiplier =
            emission_step.average_multiplier(&self.settings.emission.emission_rate_curve);
        let scaled_emission_rate_multiplier = emission_rate_multiplier * options.emission_scale;
        if self.settings.emission.emission_rate > 0.0 && scaled_emission_rate_multiplier > 0.0 {
            self.runtime.emission_accumulator += self.settings.emission.emission_rate
                * scaled_emission_rate_multiplier
                * emission_step.delta;
            let to_spawn = self.runtime.emission_accumulator as i64;
            if to_spawn > 0 {
                self.runtime.emission_accumulator -= to_spawn as f32;
                let spawn_result = self.spawn_with_budget(
                    to_spawn,
                    world_transform,
                    None,
                    inherited_world_velocity,
                    Some(live_particle_limit),
                    true,
                    &mut spawn_budget,
                );
                frame_stats.requested_spawn_count += spawn_result.requested;
                frame_stats.continuous_spawned_count += spawn_result.spawned;
                frame_stats.capacity_limited_spawn_count += spawn_result.capacity_limited_count;
                frame_stats.spawn_budget_limited_count += spawn_result.spawn_budget_limited_count;
            }
        }
        if self.settings.emission.burst_count > 0 && self.settings.emission.burst_interval > 0.0 {
            self.runtime.burst_accumulator += emission_step.delta;
            let bursts =
                (self.runtime.burst_accumulator / self.settings.emission.burst_interval) as i64;
            if bursts > 0 {
                self.runtime.burst_accumulator -=
                    bursts as f32 * self.settings.emission.burst_interval;
                self.runtime.burst_spawn_accumulator +=
                    (bursts * self.settings.emission.burst_count) as f32 * options.burst_scale;
                let to_spawn = self.runtime.burst_spawn_accumulator as i64;
                if to_spawn > 0 {
                    self.runtime.burst_spawn_accumulator -= to_spawn as f32;
                    let spawn_result = self.spawn_with_budget(
                        to_spawn,
                        world_transform,
                        None,
                        inherited_world_velocity,
                        Some(live_particle_limit),
                        true,
                        &mut spawn_budget,
                    );
                    frame_stats.requested_spawn_count += spawn_result.requested;
                    frame_stats.burst_spawned_count += spawn_result.spawned;
                    frame_stats.capacity_limited_spawn_count += spawn_result.capacity_limited_count;
                    frame_stats.spawn_budget_limited_count +=
                        spawn_result.spawn_budget_limited_count;
                }
            }
        }
        let distance_rate_multiplier =
            emission_step.average_multiplier(&self.settings.emission.distance_emission_rate_curve);
        let distance_spawn_result = self.spawn_distance_emission(
            self.runtime.previous_emitter_position,
            current_emitter_position,
            world_transform,
            inherited_world_velocity,
            distance_rate_multiplier * options.distance_emission_scale,
            Some(live_particle_limit),
            &mut spawn_budget,
        );
        frame_stats.requested_spawn_count += distance_spawn_result.requested;
        frame_stats.distance_spawned_count += distance_spawn_result.spawned;
        frame_stats.capacity_limited_spawn_count += distance_spawn_result.capacity_limited_count;
        frame_stats.spawn_budget_limited_count += distance_spawn_result.spawn_budget_limited_count;
        frame_stats.live_particle_count = self.runtime.particles.len() as i64;
        frame_stats.spawn_budget_consumed_count = spawn_budget.consumed_count;
        self.runtime.last_frame_stats = frame_stats;
    }

    /// Spawns `count` particles immediately (a burst), independent of the
    /// emission rate. Honors the `max_particles` cap.
    pub fn emit(&mut self, count: i64, world_transform: Option<Float4x4>) {
        self.spawn(count, world_transform, None, Float3::ZERO, None, false);
    }

    /// Removes all live particles and resets emission timing.
    pub fn clear(&mut self) {
        self.runtime.clear();
    }

    /// Applies collision/death events produced by an external simulation backend
    /// and spawns matching sub-emitter particles through the same rules as CPU
    /// simulation.
    pub fn apply_simulation_events(
        &mut self,
        events: &[ParticleEvent],
    ) -> ParticleEmitterFrameStats {
        self.runtime.last_frame_spawned_particles.clear();
        self.runtime.last_frame_events.clear();
        let mut frame_stats = ParticleEmitterFrameStats::new(
            0.0,
            self.runtime.particles.len() as i64,
            self.runtime.particles.len() as i64,
            self.settings.emission.max_particles,
            self.settings.emission.max_particles,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            self.settings.emission.max_spawned_particles_per_frame,
            0,
            0,
            0,
        );
        if events.is_empty() {
            self.runtime.last_frame_stats = frame_stats;
            return frame_stats;
        }

        let mut event_particles: Vec<Particle> = Vec::with_capacity(events.len());
        let mut event_sub_emitter_spawn_result = ParticleSpawnResult::new(0, 0);
        let mut spawn_budget =
            ParticleSpawnBudget::new(self.settings.emission.max_spawned_particles_per_frame);
        for event in events {
            if event.trigger == ParticleSubEmitterTrigger::None {
                continue;
            }
            let source = self.source_particle(event);
            match event.trigger {
                ParticleSubEmitterTrigger::Collision => {
                    frame_stats.collision_count += 1;
                }
                ParticleSubEmitterTrigger::Death => {
                    frame_stats.expired_particle_count += 1;
                }
                ParticleSubEmitterTrigger::None => {}
            }
            self.record_event(event.trigger, &source);
            event_sub_emitter_spawn_result.include(&self.spawn_sub_emitter_particles(
                event.trigger,
                &source,
                self.runtime.particles.len() as i64,
                &mut event_particles,
                &mut spawn_budget,
            ));
        }

        let event_spawn_result = self.append_event_particles(event_particles);
        frame_stats.requested_spawn_count += event_sub_emitter_spawn_result.requested;
        frame_stats.sub_emitter_spawned_count += event_spawn_result.spawned;
        frame_stats.capacity_limited_spawn_count += event_sub_emitter_spawn_result
            .capacity_limited_count
            + event_spawn_result.capacity_limited_count;
        frame_stats.spawn_budget_limited_count += event_sub_emitter_spawn_result
            .spawn_budget_limited_count
            + event_spawn_result.spawn_budget_limited_count;
        frame_stats.live_particle_count = self.runtime.particles.len() as i64;
        frame_stats.spawn_budget_consumed_count = spawn_budget.consumed_count;
        self.runtime.last_frame_stats = frame_stats;
        frame_stats
    }

    fn record_event(&mut self, trigger: ParticleSubEmitterTrigger, source: &Particle) {
        if trigger == ParticleSubEmitterTrigger::None {
            return;
        }
        self.runtime
            .last_frame_events
            .push(ParticleEvent::from_particle(trigger, source));
    }

    fn source_particle(&self, event: &ParticleEvent) -> Particle {
        Particle::new(
            event.position,
            event.velocity,
            event.age,
            event.lifetime,
            1.0,
            0.0,
            0.0,
            1.0,
            Float4::new(1.0, 1.0, 1.0, 1.0),
            event.generation,
            event.appearance_index,
            0,
        )
    }

    fn run_prewarm_if_needed(
        &mut self,
        world_transform: Option<Float4x4>,
        options: &ParticleAdvanceOptions,
    ) {
        if self.runtime.has_prewarmed
            || !self.settings.emission.is_emitting
            || !(self.settings.emission.prewarm_time > 0.0)
            || !(self.settings.emission.max_particles > 0)
        {
            return;
        }

        self.runtime.has_prewarmed = true;
        self.runtime.previous_emitter_position =
            Some(self.distance_emitter_position(world_transform));
        let mut remaining = self.settings.emission.prewarm_time;
        let step = swift_min_f32(
            swift_max_f32(1.0 / 240.0, self.settings.emission.prewarm_step),
            self.settings.emission.prewarm_time,
        );
        while remaining > 0.0001 {
            let dt = swift_min_f32(step, remaining);
            self.advance_step(dt, world_transform, options);
            remaining -= dt;
        }
        self.runtime.previous_emitter_position =
            Some(self.distance_emitter_position(world_transform));
    }

    fn active_emission_step(&mut self, dt: f32) -> ActiveEmissionStep {
        if !(self.settings.emission.duration > 0.0) {
            return ActiveEmissionStep {
                delta: dt,
                normalized_age: 1.0,
                start_age: 0.0,
                duration: 0.0,
                looping: false,
            };
        }
        let start_age = self.runtime.emitter_age;
        if self.settings.emission.looping {
            self.runtime.emitter_age =
                (self.runtime.emitter_age + dt) % self.settings.emission.duration;
            let sample_age = (start_age + dt * 0.5) % self.settings.emission.duration;
            return ActiveEmissionStep {
                delta: dt,
                normalized_age: simd_clamp_scalar(
                    sample_age / self.settings.emission.duration,
                    0.0,
                    1.0,
                ),
                start_age,
                duration: self.settings.emission.duration,
                looping: true,
            };
        }

        let remaining = swift_max_f32(
            0.0,
            self.settings.emission.duration - self.runtime.emitter_age,
        );
        let active_delta = swift_min_f32(dt, remaining);
        self.runtime.emitter_age += dt;
        let sample_age = start_age + active_delta * 0.5;
        ActiveEmissionStep {
            delta: active_delta,
            normalized_age: simd_clamp_scalar(
                sample_age / self.settings.emission.duration,
                0.0,
                1.0,
            ),
            start_age,
            duration: self.settings.emission.duration,
            looping: false,
        }
    }

    fn has_event_sub_emitter_rules(&self) -> bool {
        self.legacy_sub_emitter_rule().is_some()
            || self
                .settings
                .sub_emitters
                .rules
                .iter()
                .any(|rule| rule.is_active())
    }
}

struct ActiveEmissionStep {
    delta: f32,
    normalized_age: f32,
    start_age: f32,
    duration: f32,
    looping: bool,
}

impl ActiveEmissionStep {
    fn average_multiplier(&self, curve: &ParticleCurve) -> f32 {
        if !(self.duration > 0.0) || !(self.delta > 0.0) {
            return swift_max_f32(0.0, curve.evaluate(self.normalized_age));
        }
        let samples = ActiveEmissionStep::average_curve_sample_count(self.delta, self.duration);
        if samples <= 1 {
            return swift_max_f32(0.0, curve.evaluate(self.normalized_age));
        }

        let mut total: f32 = 0.0;
        for index in 0..samples {
            let t = (index as f32 + 0.5) / samples as f32;
            let mut age = self.start_age + self.delta * t;
            if self.looping {
                age %= self.duration;
                if age < 0.0 {
                    age += self.duration;
                }
            } else {
                age = swift_min_f32(swift_max_f32(0.0, age), self.duration);
            }
            total += swift_max_f32(
                0.0,
                curve.evaluate(simd_clamp_scalar(age / self.duration, 0.0, 1.0)),
            );
        }
        total / samples as f32
    }

    fn average_curve_sample_count(delta: f32, duration: f32) -> i64 {
        if !(delta > 0.0) || !(duration > 0.0) {
            return 1;
        }
        let samples_per_cycle: f32 = 8.0;
        let raw_samples = ((delta / duration) * samples_per_cycle).ceil() as i64;
        raw_samples.clamp(1, 32)
    }
}

#[inline]
fn swift_max_f32(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}

#[inline]
fn swift_min_f32(x: f32, y: f32) -> f32 {
    if y < x { y } else { x }
}
