//! `Editor/Sources/EditorCore/Scene/Manifest/Settings.swift`.
//!
//! Persisted spellings of the physics and particle settings the editor owns.
//! Reading them never fails on a missing optional: each falls back to the
//! runtime resource's own default, exactly like the Swift initializers.

use diffuse_scene::particles::particle_scalability::{
    ParticleScalabilityPolicyResource, ParticleScalabilityResource,
};
use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
use diffuse_scene::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use diffuse_scene::physics::physics_types::PhysicsSimulationMode;
use serde::{Deserialize, Deserializer, Serialize};

use crate::scene::manifest::transform_math::EditorSceneManifestVector3;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSceneManifestPhysicsSettings {
    pub simulation_mode: String,
    pub backend_kind: String,
    pub gravity: EditorSceneManifestVector3,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub fixed_time_step_seconds: f64,
    pub max_substeps_per_frame: i64,
    pub allow_sleep: bool,
    pub collision_steps: i64,
    pub capacity: PhysicsCapacitySettings,
}

impl<'de> Deserialize<'de> for EditorSceneManifestPhysicsSettings {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Raw {
            simulation_mode: String,
            #[serde(default)]
            backend_kind: Option<String>,
            gravity: EditorSceneManifestVector3,
            fixed_time_step_seconds: f64,
            max_substeps_per_frame: i64,
            allow_sleep: bool,
            #[serde(default)]
            collision_steps: Option<i64>,
            #[serde(default)]
            capacity: Option<PhysicsCapacitySettings>,
        }
        let raw = Raw::deserialize(deserializer)?;
        let backend_kind = raw
            .backend_kind
            .as_deref()
            .and_then(PhysicsBackendKind::from_raw_value)
            .unwrap_or_else(PhysicsBackendKind::preferred);
        Ok(EditorSceneManifestPhysicsSettings {
            simulation_mode: raw.simulation_mode,
            backend_kind: backend_kind.raw_value().to_string(),
            gravity: raw.gravity,
            fixed_time_step_seconds: raw.fixed_time_step_seconds,
            max_substeps_per_frame: raw.max_substeps_per_frame,
            allow_sleep: raw.allow_sleep,
            collision_steps: raw.collision_steps.unwrap_or(1),
            capacity: raw.capacity.unwrap_or_default(),
        })
    }
}

impl EditorSceneManifestPhysicsSettings {
    pub fn new(settings: &PhysicsSettingsResource) -> Self {
        EditorSceneManifestPhysicsSettings {
            simulation_mode: settings.simulation_mode.raw_value().to_string(),
            backend_kind: settings.backend_kind.raw_value().to_string(),
            gravity: EditorSceneManifestVector3::from_simd(settings.gravity),
            fixed_time_step_seconds: settings.fixed_time_step_seconds,
            max_substeps_per_frame: settings.max_substeps_per_frame,
            allow_sleep: settings.allow_sleep,
            collision_steps: settings.collision_steps,
            capacity: settings.capacity,
        }
    }

    /// The runtime resource, re-validated through its initializer.
    pub fn settings(&self) -> PhysicsSettingsResource {
        PhysicsSettingsResource::new(
            PhysicsSimulationMode::from_raw_value(&self.simulation_mode)
                .unwrap_or(PhysicsSimulationMode::Off),
            PhysicsBackendKind::from_raw_value(&self.backend_kind)
                .unwrap_or_else(PhysicsBackendKind::preferred),
            self.gravity.simd_value(),
            self.fixed_time_step_seconds,
            self.max_substeps_per_frame,
            self.allow_sleep,
            self.collision_steps,
            self.capacity,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSceneManifestParticleScalability {
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub emission_scale: f32,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub burst_scale: f32,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub distance_emission_scale: f32,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub max_live_particle_scale: f32,
}

impl EditorSceneManifestParticleScalability {
    pub fn new(settings: &ParticleScalabilityResource) -> Self {
        EditorSceneManifestParticleScalability {
            emission_scale: settings.emission_scale,
            burst_scale: settings.burst_scale,
            distance_emission_scale: settings.distance_emission_scale,
            max_live_particle_scale: settings.max_live_particle_scale,
        }
    }

    pub fn settings(&self) -> ParticleScalabilityResource {
        ParticleScalabilityResource::new(
            self.emission_scale,
            self.burst_scale,
            self.distance_emission_scale,
            self.max_live_particle_scale,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSceneManifestParticleScalabilityPolicy {
    pub is_enabled: bool,
    pub target_live_particles: i64,
    pub target_spawned_particles_per_frame: i64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub minimum_scale: f32,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub pressure_step: f32,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub recovery_step: f32,
}

impl EditorSceneManifestParticleScalabilityPolicy {
    pub fn new(policy: &ParticleScalabilityPolicyResource) -> Self {
        EditorSceneManifestParticleScalabilityPolicy {
            is_enabled: policy.is_enabled,
            target_live_particles: policy.target_live_particles,
            target_spawned_particles_per_frame: policy.target_spawned_particles_per_frame,
            minimum_scale: policy.minimum_scale,
            pressure_step: policy.pressure_step,
            recovery_step: policy.recovery_step,
        }
    }

    pub fn policy(&self) -> ParticleScalabilityPolicyResource {
        ParticleScalabilityPolicyResource::new(
            self.is_enabled,
            self.target_live_particles,
            self.target_spawned_particles_per_frame,
            self.minimum_scale,
            self.pressure_step,
            self.recovery_step,
        )
    }
}
