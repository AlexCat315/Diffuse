//! Physics world capacity and simulation settings.

use diffuse_math::simd::simd_compat::Float3;

use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::physics_types::PhysicsSimulationMode;

/// Capacity limits for the physics world.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PhysicsCapacitySettings {
    pub max_bodies: i64,
    /// Zero selects the platform default: the available logical core count minus one.
    pub worker_thread_count: i64,
}

impl PhysicsCapacitySettings {
    pub fn new(max_bodies: i64, worker_thread_count: i64) -> Self {
        PhysicsCapacitySettings {
            max_bodies: max_bodies.clamp(1, u32::MAX as i64),
            worker_thread_count: worker_thread_count.clamp(0, 1_024),
        }
    }
}

impl Default for PhysicsCapacitySettings {
    fn default() -> Self {
        PhysicsCapacitySettings::new(65_536, 0)
    }
}

impl serde::Serialize for PhysicsCapacitySettings {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut state = serializer.serialize_struct("PhysicsCapacitySettings", 2)?;
        state.serialize_field("maxBodies", &self.max_bodies)?;
        state.serialize_field("workerThreadCount", &self.worker_thread_count)?;
        state.end()
    }
}

impl<'de> serde::Deserialize<'de> for PhysicsCapacitySettings {
    /// Reproduces Swift's custom `init(from:)`: missing keys fall back to the
    /// defaults, and both values are re-validated through `init`.
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Raw {
            #[serde(default)]
            max_bodies: Option<i64>,
            #[serde(default)]
            worker_thread_count: Option<i64>,
        }
        let raw = Raw::deserialize(deserializer)?;
        let defaults = PhysicsCapacitySettings::default();
        Ok(PhysicsCapacitySettings::new(
            raw.max_bodies.unwrap_or(defaults.max_bodies),
            raw.worker_thread_count
                .unwrap_or(defaults.worker_thread_count),
        ))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsSettingsResource {
    pub simulation_mode: PhysicsSimulationMode,
    pub backend_kind: PhysicsBackendKind,
    pub gravity: Float3,
    pub fixed_time_step_seconds: f64,
    pub max_substeps_per_frame: i64,
    pub allow_sleep: bool,
    pub collision_steps: i64,
    pub capacity: PhysicsCapacitySettings,
}

impl PhysicsSettingsResource {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        simulation_mode: PhysicsSimulationMode,
        backend_kind: PhysicsBackendKind,
        gravity: Float3,
        fixed_time_step_seconds: f64,
        max_substeps_per_frame: i64,
        allow_sleep: bool,
        collision_steps: i64,
        capacity: PhysicsCapacitySettings,
    ) -> Self {
        PhysicsSettingsResource {
            simulation_mode,
            backend_kind,
            gravity,
            fixed_time_step_seconds: fixed_time_step_seconds.max(0.000_001),
            max_substeps_per_frame: max_substeps_per_frame.max(1),
            allow_sleep,
            collision_steps: collision_steps.max(1),
            capacity,
        }
    }
}

impl Default for PhysicsSettingsResource {
    /// Swift's memberwise defaults: simulation off, preferred backend, standard
    /// gravity, 60 Hz, 4 substeps, 1 collision step.
    fn default() -> Self {
        PhysicsSettingsResource::new(
            PhysicsSimulationMode::Off,
            PhysicsBackendKind::preferred(),
            Float3::new(0.0, -9.81, 0.0),
            1.0 / 60.0,
            4,
            true,
            1,
            PhysicsCapacitySettings::default(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capacity_clamps_bounds() {
        let low = PhysicsCapacitySettings::new(0, -5);
        assert_eq!(low.max_bodies, 1);
        assert_eq!(low.worker_thread_count, 0);

        let high = PhysicsCapacitySettings::new(i64::MAX, 9_999);
        assert_eq!(high.max_bodies, u32::MAX as i64);
        assert_eq!(high.worker_thread_count, 1_024);
    }

    #[test]
    fn capacity_defaults_match_swift() {
        let settings = PhysicsCapacitySettings::default();
        assert_eq!(settings.max_bodies, 65_536);
        assert_eq!(settings.worker_thread_count, 0);
    }

    #[test]
    fn settings_defaults_match_swift() {
        let settings = PhysicsSettingsResource::default();
        assert_eq!(settings.simulation_mode, PhysicsSimulationMode::Off);
        assert_eq!(settings.backend_kind, PhysicsBackendKind::Natsel);
        assert_eq!(settings.gravity, Float3::new(0.0, -9.81, 0.0));
        assert_eq!(settings.max_substeps_per_frame, 4);
        assert_eq!(settings.collision_steps, 1);
        assert!(settings.allow_sleep);
    }

    #[test]
    fn timestep_and_counts_have_floors() {
        let settings = PhysicsSettingsResource::new(
            PhysicsSimulationMode::Play,
            PhysicsBackendKind::None,
            Float3::ZERO,
            0.0,
            0,
            false,
            0,
            PhysicsCapacitySettings::default(),
        );
        assert_eq!(settings.fixed_time_step_seconds, 0.000_001);
        assert_eq!(settings.max_substeps_per_frame, 1);
        assert_eq!(settings.collision_steps, 1);
    }

    #[test]
    fn capacity_deserializes_missing_keys_to_defaults() {
        let settings: PhysicsCapacitySettings =
            serde_json::from_str(r#"{"maxBodies": 128}"#).expect("decode");
        assert_eq!(settings.max_bodies, 128);
        assert_eq!(settings.worker_thread_count, 0);
    }

    /// The expected text was produced by Swift 6.4.1 encoding the original
    /// `PhysicsCapacitySettings` with `JSONEncoder.outputFormatting = [.sortedKeys]`,
    /// which is the only configuration with a stable byte target.
    ///
    /// Measured caveat: a default `JSONEncoder()` (no `.sortedKeys`) emits keys in a
    /// *randomized* order that differs between processes — verified with both
    /// synthesized and explicit `CodingKeys`, five runs giving five orders. So there
    /// is no "declaration order" fallback to reproduce; byte-identity is defined
    /// solely against `.sortedKeys`.
    #[test]
    fn capacity_round_trips_through_json() {
        let settings = PhysicsCapacitySettings::new(256, 8);
        let text = serde_json::to_string(&settings).expect("encode");
        assert_eq!(text, r#"{"maxBodies":256,"workerThreadCount":8}"#);
        let decoded: PhysicsCapacitySettings = serde_json::from_str(&text).expect("decode");
        assert_eq!(decoded, settings);
    }
}
