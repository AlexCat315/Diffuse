//! Whether an emitter's authored modules can run on the GPU simulation path.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleGPUSimulationPlan.swift`.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_types::ParticleSimulationBackend;

macro_rules! plan_string_enum {
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

plan_string_enum! {
    ParticleGPUSimulationPlanStatus {
        Disabled => "disabled",
        Supported => "supported",
        FallbackToCpu => "fallbackToCPU",
        RequiredButUnsupported => "requiredButUnsupported",
    }
}

impl ParticleGPUSimulationPlanStatus {
    pub const ALL: [ParticleGPUSimulationPlanStatus; 4] = [
        ParticleGPUSimulationPlanStatus::Disabled,
        ParticleGPUSimulationPlanStatus::Supported,
        ParticleGPUSimulationPlanStatus::FallbackToCpu,
        ParticleGPUSimulationPlanStatus::RequiredButUnsupported,
    ];
}

plan_string_enum! {
    ParticleGPUSimulationUnsupportedReason {
        BackendCpu => "backendCPU",
        NoParticleCapacity => "noParticleCapacity",
        EventSubEmitters => "eventSubEmitters",
        DistanceEmission => "distanceEmission",
        Noise => "noise",
        ForceFields => "forceFields",
        Collisions => "collisions",
        AngularVelocity => "angularVelocity",
    }
}

impl ParticleGPUSimulationUnsupportedReason {
    pub const ALL: [ParticleGPUSimulationUnsupportedReason; 8] = [
        ParticleGPUSimulationUnsupportedReason::BackendCpu,
        ParticleGPUSimulationUnsupportedReason::NoParticleCapacity,
        ParticleGPUSimulationUnsupportedReason::EventSubEmitters,
        ParticleGPUSimulationUnsupportedReason::DistanceEmission,
        ParticleGPUSimulationUnsupportedReason::Noise,
        ParticleGPUSimulationUnsupportedReason::ForceFields,
        ParticleGPUSimulationUnsupportedReason::Collisions,
        ParticleGPUSimulationUnsupportedReason::AngularVelocity,
    ];
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParticleGPUSimulationPlan {
    pub backend: ParticleSimulationBackend,
    pub status: ParticleGPUSimulationPlanStatus,
    pub particle_capacity: i64,
    pub workgroup_size: i64,
    pub dispatch_workgroups: i64,
    pub unsupported_reasons: Vec<ParticleGPUSimulationUnsupportedReason>,
}

impl ParticleGPUSimulationPlan {
    pub const MAXIMUM_WORKGROUP_SIZE: i64 = 256;

    pub fn new(emitter: &ParticleEmitter) -> Self {
        let backend = emitter.settings.gpu_simulation.simulation_backend;
        let particle_capacity = emitter.settings.emission.max_particles.max(0);
        let workgroup_size = emitter
            .settings
            .gpu_simulation
            .workgroup_size
            .max(1)
            .min(Self::MAXIMUM_WORKGROUP_SIZE);
        let dispatch_workgroups = if particle_capacity > 0 {
            (particle_capacity as f32 / workgroup_size as f32).ceil() as i64
        } else {
            0
        };

        let mut reasons: Vec<ParticleGPUSimulationUnsupportedReason> = Vec::new();
        if emitter.settings.gpu_simulation.simulation_backend == ParticleSimulationBackend::Cpu {
            reasons.push(ParticleGPUSimulationUnsupportedReason::BackendCpu);
        }
        if particle_capacity == 0 {
            reasons.push(ParticleGPUSimulationUnsupportedReason::NoParticleCapacity);
        }

        let status = if emitter.settings.gpu_simulation.simulation_backend
            == ParticleSimulationBackend::Cpu
        {
            ParticleGPUSimulationPlanStatus::Disabled
        } else if reasons.is_empty() {
            ParticleGPUSimulationPlanStatus::Supported
        } else if emitter.settings.gpu_simulation.simulation_backend
            == ParticleSimulationBackend::GpuRequired
        {
            ParticleGPUSimulationPlanStatus::RequiredButUnsupported
        } else {
            ParticleGPUSimulationPlanStatus::FallbackToCpu
        };

        ParticleGPUSimulationPlan {
            backend,
            status,
            particle_capacity,
            workgroup_size,
            dispatch_workgroups,
            unsupported_reasons: reasons,
        }
    }

    pub fn uses_gpu(&self) -> bool {
        self.status == ParticleGPUSimulationPlanStatus::Supported
    }
}
