//! Runtime particle scalability resources and the pressure policy.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleScalability.swift`.

use diffuse_math::simd::simd_compat::simd_clamp_scalar;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::particles::particle_stats::ParticleFrameStatsResource;
use crate::particles::particle_types::ParticleAdvanceOptions;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParticleScalabilityResource {
    pub emission_scale: f32,
    pub burst_scale: f32,
    pub distance_emission_scale: f32,
    pub max_live_particle_scale: f32,
}

impl ParticleScalabilityResource {
    pub fn new(
        emission_scale: f32,
        burst_scale: f32,
        distance_emission_scale: f32,
        max_live_particle_scale: f32,
    ) -> Self {
        // The clamps live in `ParticleAdvanceOptions`.
        let options = ParticleAdvanceOptions::new(
            emission_scale,
            burst_scale,
            distance_emission_scale,
            max_live_particle_scale,
        );
        ParticleScalabilityResource {
            emission_scale: options.emission_scale,
            burst_scale: options.burst_scale,
            distance_emission_scale: options.distance_emission_scale,
            max_live_particle_scale: options.max_live_particle_scale,
        }
    }

    pub fn advance_options(&self) -> ParticleAdvanceOptions {
        ParticleAdvanceOptions::new(
            self.emission_scale,
            self.burst_scale,
            self.distance_emission_scale,
            self.max_live_particle_scale,
        )
    }
}

impl Default for ParticleScalabilityResource {
    fn default() -> Self {
        ParticleScalabilityResource::new(1.0, 1.0, 1.0, 1.0)
    }
}

macro_rules! scalability_string_enum {
    (
        $(#[$meta:meta])*
        $name:ident { $($(#[$variant_meta:meta])* $variant:ident => $raw:literal),+ $(,)? }
    ) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub enum $name {
            $($(#[$variant_meta])* $variant),+
        }

        impl $name {
            pub const fn raw_value(&self) -> &'static str {
                match self {
                    $($name::$variant => $raw),+
                }
            }

            pub fn from_raw_value(value: &str) -> Option<Self> {
                match value {
                    $($raw => Some($name::$variant),)+
                    _ => None,
                }
            }
        }

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(self.raw_value())
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let value = String::deserialize(deserializer)?;
                $name::from_raw_value(&value).ok_or_else(|| {
                    serde::de::Error::custom(format!("Unknown {}: {value}", stringify!($name)))
                })
            }
        }
    };
}

scalability_string_enum! {
    ParticleScalabilityPressureReason {
        None => "none",
        LiveBudget => "liveBudget",
        SpawnBudget => "spawnBudget",
        CapacityLimited => "capacityLimited",
    }
}

impl ParticleScalabilityPressureReason {
    pub const ALL: [ParticleScalabilityPressureReason; 4] = [
        ParticleScalabilityPressureReason::None,
        ParticleScalabilityPressureReason::LiveBudget,
        ParticleScalabilityPressureReason::SpawnBudget,
        ParticleScalabilityPressureReason::CapacityLimited,
    ];
}

scalability_string_enum! {
    ParticleRuntimePressureLevel {
        Idle => "idle",
        Nominal => "nominal",
        Warning => "warning",
        Critical => "critical",
    }
}

impl ParticleRuntimePressureLevel {
    pub const ALL: [ParticleRuntimePressureLevel; 4] = [
        ParticleRuntimePressureLevel::Idle,
        ParticleRuntimePressureLevel::Nominal,
        ParticleRuntimePressureLevel::Warning,
        ParticleRuntimePressureLevel::Critical,
    ];
}

pub(crate) fn dominant_particle_runtime_pressure_level(
    lhs: ParticleRuntimePressureLevel,
    rhs: ParticleRuntimePressureLevel,
) -> ParticleRuntimePressureLevel {
    if particle_runtime_pressure_rank(lhs) >= particle_runtime_pressure_rank(rhs) {
        lhs
    } else {
        rhs
    }
}

fn particle_runtime_pressure_rank(level: ParticleRuntimePressureLevel) -> i64 {
    match level {
        ParticleRuntimePressureLevel::Idle => 0,
        ParticleRuntimePressureLevel::Nominal => 1,
        ParticleRuntimePressureLevel::Warning => 2,
        ParticleRuntimePressureLevel::Critical => 3,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParticleScalabilityStateResource {
    pub applied_scale: f32,
    pub pressure: f32,
    pub reason: ParticleScalabilityPressureReason,
}

impl ParticleScalabilityStateResource {
    pub fn new(
        applied_scale: f32,
        pressure: f32,
        reason: ParticleScalabilityPressureReason,
    ) -> Self {
        ParticleScalabilityStateResource {
            applied_scale: simd_clamp_scalar(applied_scale, 0.0, 1.0),
            pressure: simd_clamp_scalar(pressure, 0.0, 10.0),
            reason,
        }
    }

    pub fn applying(&self, base: ParticleAdvanceOptions) -> ParticleAdvanceOptions {
        ParticleAdvanceOptions::new(
            base.emission_scale * self.applied_scale,
            base.burst_scale * self.applied_scale,
            base.distance_emission_scale * self.applied_scale,
            base.max_live_particle_scale * self.applied_scale,
        )
    }
}

impl Default for ParticleScalabilityStateResource {
    fn default() -> Self {
        ParticleScalabilityStateResource::new(1.0, 0.0, ParticleScalabilityPressureReason::None)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParticleScalabilityPolicyResource {
    pub is_enabled: bool,
    pub target_live_particles: i64,
    pub target_spawned_particles_per_frame: i64,
    pub minimum_scale: f32,
    pub pressure_step: f32,
    pub recovery_step: f32,
}

impl ParticleScalabilityPolicyResource {
    pub fn new(
        is_enabled: bool,
        target_live_particles: i64,
        target_spawned_particles_per_frame: i64,
        minimum_scale: f32,
        pressure_step: f32,
        recovery_step: f32,
    ) -> Self {
        ParticleScalabilityPolicyResource {
            is_enabled,
            target_live_particles: target_live_particles.max(0),
            target_spawned_particles_per_frame: target_spawned_particles_per_frame.max(0),
            minimum_scale: simd_clamp_scalar(minimum_scale, 0.0, 1.0),
            pressure_step: simd_clamp_scalar(pressure_step, 0.0, 1.0),
            recovery_step: simd_clamp_scalar(recovery_step, 0.0, 1.0),
        }
    }

    pub fn disabled() -> Self {
        ParticleScalabilityPolicyResource::new(false, 0, 0, 0.25, 0.15, 0.05)
    }

    pub fn updated_state(
        &self,
        previous_stats: &ParticleFrameStatsResource,
        previous_state: ParticleScalabilityStateResource,
    ) -> ParticleScalabilityStateResource {
        if !self.is_enabled {
            return ParticleScalabilityStateResource::default();
        }

        let pressure_sample = self.pressure(previous_stats);
        let next_scale: f32 = if pressure_sample.0 > 0.0 {
            let reduction = self.pressure_step * pressure_sample.0.min(1.0);
            self.minimum_scale
                .max(previous_state.applied_scale * (1.0 - reduction))
        } else {
            1.0_f32.min(previous_state.applied_scale + self.recovery_step)
        };
        ParticleScalabilityStateResource::new(
            next_scale,
            pressure_sample.0,
            pressure_sample.1,
        )
    }

    fn pressure(
        &self,
        stats: &ParticleFrameStatsResource,
    ) -> (f32, ParticleScalabilityPressureReason) {
        if stats.capacity_limited_spawn_count > 0 {
            return (1.0, ParticleScalabilityPressureReason::CapacityLimited);
        }
        if stats.spawn_budget_limited_count > 0 || stats.gpu_dropped_spawn_count > 0 {
            return (1.0, ParticleScalabilityPressureReason::SpawnBudget);
        }

        let mut pressure: f32 = 0.0;
        let mut reason = ParticleScalabilityPressureReason::None;
        let live_particle_count = stats.live_particle_count.max(stats.gpu_alive_particle_count);
        if self.target_live_particles > 0 && live_particle_count > self.target_live_particles {
            pressure = pressure.max(
                (live_particle_count - self.target_live_particles) as f32
                    / self.target_live_particles as f32,
            );
            reason = ParticleScalabilityPressureReason::LiveBudget;
        }
        if self.target_spawned_particles_per_frame > 0
            && stats.spawned_particle_count > self.target_spawned_particles_per_frame
        {
            let spawn_pressure = (stats.spawned_particle_count
                - self.target_spawned_particles_per_frame) as f32
                / self.target_spawned_particles_per_frame as f32;
            if spawn_pressure > pressure {
                pressure = spawn_pressure;
                reason = ParticleScalabilityPressureReason::SpawnBudget;
            }
        }
        (pressure, reason)
    }
}

impl Default for ParticleScalabilityPolicyResource {
    fn default() -> Self {
        ParticleScalabilityPolicyResource::disabled()
    }
}
