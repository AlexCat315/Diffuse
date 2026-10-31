//! Live particle state and the small authoring enums shared by the particle modules.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleTypes.swift`.

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_clamp_scalar};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A single live particle owned by a `ParticleEmitter`. Positions/velocities are
/// stored in the emitter's configured simulation space; `size`/`color` are
/// re-derived from `age` each step so the render backend can consume them
/// directly without re-evaluating the gradient.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Particle {
    pub position: Float3,
    pub velocity: Float3,
    pub age: f32,
    pub lifetime: f32,
    pub size_scale: f32,
    pub rotation: f32,
    pub angular_velocity: f32,
    pub size: f32,
    pub color: Float4,
    pub generation: u8,
    pub appearance_index: u16,
    pub texture_frame_seed: u16,
}

impl Particle {
    /// `init(position:velocity:age:lifetime:sizeScale:rotation:angularVelocity:size:color:generation:appearanceIndex:textureFrameSeed:)`
    /// — the Swift defaults expanded in declaration order.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        position: Float3,
        velocity: Float3,
        age: f32,
        lifetime: f32,
        size_scale: f32,
        rotation: f32,
        angular_velocity: f32,
        size: f32,
        color: Float4,
        generation: u8,
        appearance_index: u16,
        texture_frame_seed: u16,
    ) -> Self {
        Particle {
            position,
            velocity,
            age,
            lifetime,
            size_scale,
            rotation,
            angular_velocity,
            size,
            color,
            generation,
            appearance_index,
            texture_frame_seed,
        }
    }

    /// Normalized life progress in 0...1.
    pub fn normalized_age(&self) -> f32 {
        if self.lifetime > 0.0 {
            simd_clamp_scalar(self.age / self.lifetime, 0.0, 1.0)
        } else {
            1.0
        }
    }
}

macro_rules! swift_string_enum {
    (
        $(#[$meta:meta])*
        $name:ident { $($(#[$variant_meta:meta])* $variant:ident => $raw:literal),+ $(,)? }
    ) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
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

swift_string_enum! {
    ParticleEmissionShape {
        Sphere => "sphere",
        Box => "box",
        Cone => "cone",
    }
}

impl ParticleEmissionShape {
    pub const ALL: [ParticleEmissionShape; 3] = [
        ParticleEmissionShape::Sphere,
        ParticleEmissionShape::Box,
        ParticleEmissionShape::Cone,
    ];
}

swift_string_enum! {
    ParticleCollisionMode {
        None => "none",
        LocalPlane => "localPlane",
        WorldPlane => "worldPlane",
    }
}

impl ParticleCollisionMode {
    pub const ALL: [ParticleCollisionMode; 3] = [
        ParticleCollisionMode::None,
        ParticleCollisionMode::LocalPlane,
        ParticleCollisionMode::WorldPlane,
    ];
}

swift_string_enum! {
    /// Particles are stored in emitter-local space and follow the entity transform,
    /// or in world space after spawning and remain independent of later emitter motion.
    ParticleSimulationSpace {
        Local => "local",
        World => "world",
    }
}

impl ParticleSimulationSpace {
    pub const ALL: [ParticleSimulationSpace; 2] =
        [ParticleSimulationSpace::Local, ParticleSimulationSpace::World];
}

swift_string_enum! {
    /// CPU simulation is authoritative, GPU simulation is used when supported,
    /// or GPU simulation is required.
    ParticleSimulationBackend {
        Cpu => "cpu",
        GpuIfSupported => "gpuIfSupported",
        GpuRequired => "gpuRequired",
    }
}

impl ParticleSimulationBackend {
    pub const ALL: [ParticleSimulationBackend; 3] = [
        ParticleSimulationBackend::Cpu,
        ParticleSimulationBackend::GpuIfSupported,
        ParticleSimulationBackend::GpuRequired,
    ];
}

swift_string_enum! {
    ParticleRenderBoundsMode {
        Disabled => "disabled",
        Manual => "manual",
        Automatic => "automatic",
    }
}

impl ParticleRenderBoundsMode {
    pub const ALL: [ParticleRenderBoundsMode; 3] = [
        ParticleRenderBoundsMode::Disabled,
        ParticleRenderBoundsMode::Manual,
        ParticleRenderBoundsMode::Automatic,
    ];
}

/// Runtime scaling applied to one emitter advance.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParticleAdvanceOptions {
    pub emission_scale: f32,
    pub burst_scale: f32,
    pub distance_emission_scale: f32,
    pub max_live_particle_scale: f32,
}

impl ParticleAdvanceOptions {
    pub fn new(
        emission_scale: f32,
        burst_scale: f32,
        distance_emission_scale: f32,
        max_live_particle_scale: f32,
    ) -> Self {
        ParticleAdvanceOptions {
            emission_scale: simd_clamp_scalar(emission_scale, 0.0, 10.0),
            burst_scale: simd_clamp_scalar(burst_scale, 0.0, 10.0),
            distance_emission_scale: simd_clamp_scalar(distance_emission_scale, 0.0, 10.0),
            max_live_particle_scale: simd_clamp_scalar(max_live_particle_scale, 0.0, 1.0),
        }
    }

    pub fn live_particle_limit(&self, configured_max_particles: i64) -> i64 {
        let configured = configured_max_particles.max(0);
        if configured <= 0 {
            return 0;
        }
        if self.max_live_particle_scale >= 1.0 {
            return configured;
        }
        if self.max_live_particle_scale <= 0.0 {
            return 0;
        }
        configured.min(1.max((configured as f32 * self.max_live_particle_scale).floor() as i64))
    }
}

impl Default for ParticleAdvanceOptions {
    fn default() -> Self {
        ParticleAdvanceOptions::new(1.0, 1.0, 1.0, 1.0)
    }
}

swift_string_enum! {
    ParticleBlendMode {
        Alpha => "alpha",
        Additive => "additive",
    }
}

impl ParticleBlendMode {
    pub const ALL: [ParticleBlendMode; 2] =
        [ParticleBlendMode::Alpha, ParticleBlendMode::Additive];
}

swift_string_enum! {
    ParticleRenderMode {
        Billboard => "billboard",
        Ribbon => "ribbon",
    }
}

impl ParticleRenderMode {
    pub const ALL: [ParticleRenderMode; 2] =
        [ParticleRenderMode::Billboard, ParticleRenderMode::Ribbon];
}

swift_string_enum! {
    ParticleSortMode {
        /// Transparent-safe default: farther particles are submitted first.
        DistanceDescending => "distanceDescending",
        /// Nearer particles are submitted first.
        DistanceAscending => "distanceAscending",
        /// Older particles are submitted first.
        OldestFirst => "oldestFirst",
        /// Younger particles are submitted first.
        YoungestFirst => "youngestFirst",
    }
}

impl ParticleSortMode {
    pub const ALL: [ParticleSortMode; 4] = [
        ParticleSortMode::DistanceDescending,
        ParticleSortMode::DistanceAscending,
        ParticleSortMode::OldestFirst,
        ParticleSortMode::YoungestFirst,
    ];
}

swift_string_enum! {
    ParticleTextureSheetPlaybackMode {
        /// Preserve legacy behavior: FPS playback when frame rate is positive,
        /// otherwise lifetime mapping.
        Automatic => "automatic",
        /// Map the particle's normalized lifetime across the sheet once.
        Lifetime => "lifetime",
        /// Advance by `textureSheetFrameRate` and hold the last frame.
        PlayOnce => "playOnce",
        /// Advance by `textureSheetFrameRate` and wrap inside the authored frame count.
        Loop => "loop",
        /// Hold `textureSheetStartFrame`, with optional per-particle random offset.
        SingleFrame => "singleFrame",
    }
}

impl ParticleTextureSheetPlaybackMode {
    pub const ALL: [ParticleTextureSheetPlaybackMode; 5] = [
        ParticleTextureSheetPlaybackMode::Automatic,
        ParticleTextureSheetPlaybackMode::Lifetime,
        ParticleTextureSheetPlaybackMode::PlayOnce,
        ParticleTextureSheetPlaybackMode::Loop,
        ParticleTextureSheetPlaybackMode::SingleFrame,
    ];
}

swift_string_enum! {
    ParticleRenderAlignment {
        Billboard => "billboard",
        Velocity => "velocity",
    }
}

impl ParticleRenderAlignment {
    pub const ALL: [ParticleRenderAlignment; 2] = [
        ParticleRenderAlignment::Billboard,
        ParticleRenderAlignment::Velocity,
    ];
}

swift_string_enum! {
    ParticleForceMode {
        None => "none",
        Radial => "radial",
        Vortex => "vortex",
    }
}

impl ParticleForceMode {
    pub const ALL: [ParticleForceMode; 3] = [
        ParticleForceMode::None,
        ParticleForceMode::Radial,
        ParticleForceMode::Vortex,
    ];
}

swift_string_enum! {
    ParticleVectorFieldMode {
        None => "none",
        Uniform => "uniform",
        Curl => "curl",
    }
}

impl ParticleVectorFieldMode {
    pub const ALL: [ParticleVectorFieldMode; 3] = [
        ParticleVectorFieldMode::None,
        ParticleVectorFieldMode::Uniform,
        ParticleVectorFieldMode::Curl,
    ];
}

swift_string_enum! {
    ParticleSubEmitterTrigger {
        None => "none",
        Death => "death",
        Collision => "collision",
    }
}

impl ParticleSubEmitterTrigger {
    pub const ALL: [ParticleSubEmitterTrigger; 3] = [
        ParticleSubEmitterTrigger::None,
        ParticleSubEmitterTrigger::Death,
        ParticleSubEmitterTrigger::Collision,
    ];
}
