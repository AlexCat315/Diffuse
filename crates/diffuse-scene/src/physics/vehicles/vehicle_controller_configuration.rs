//! Vehicle controller selection: wheeled, tracked and motorcycle.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VehicleControllerKind {
    Wheeled,
    Tracked,
    Motorcycle,
}

impl VehicleControllerKind {
    /// `UInt8`-backed and `Codable`.
    pub const fn raw_value(&self) -> u8 {
        match self {
            VehicleControllerKind::Wheeled => 0,
            VehicleControllerKind::Tracked => 1,
            VehicleControllerKind::Motorcycle => 2,
        }
    }

    pub const fn from_raw_value(value: u8) -> Option<Self> {
        match value {
            0 => Some(VehicleControllerKind::Wheeled),
            1 => Some(VehicleControllerKind::Tracked),
            2 => Some(VehicleControllerKind::Motorcycle),
            _ => None,
        }
    }

    pub const ALL: [VehicleControllerKind; 3] = [
        VehicleControllerKind::Wheeled,
        VehicleControllerKind::Tracked,
        VehicleControllerKind::Motorcycle,
    ];
}

impl serde::Serialize for VehicleControllerKind {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u8(self.raw_value())
    }
}

impl<'de> serde::Deserialize<'de> for VehicleControllerKind {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = u8::deserialize(deserializer)?;
        VehicleControllerKind::from_raw_value(value).ok_or_else(|| {
            serde::de::Error::custom(format!("Unknown vehicle controller kind: {value}"))
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleTrackConfiguration {
    pub driven_wheel: i64,
    pub wheels: [i64; 3],
    pub inertia: f32,
    pub angular_damping: f32,
    pub max_brake_torque: f32,
    pub differential_ratio: f32,
}

impl VehicleTrackConfiguration {
    pub fn new(driven_wheel: i64, wheels: Vec<i64>) -> Self {
        VehicleTrackConfiguration {
            driven_wheel,
            // Swift takes `[Int]`; the tracked-vehicle defaults always supply
            // exactly three wheel indices. Extra entries are ignored, missing ones
            // become `-1` so the array length is fixed rather than lossy.
            wheels: [
                *wheels.first().unwrap_or(&-1),
                *wheels.get(1).unwrap_or(&-1),
                *wheels.get(2).unwrap_or(&-1),
            ],
            inertia: 10.0,
            angular_damping: 0.5,
            max_brake_torque: 15_000.0,
            differential_ratio: 6.0,
        }
    }

    pub fn with_wheels(
        driven_wheel: i64,
        wheels: Vec<i64>,
        inertia: f32,
        angular_damping: f32,
        max_brake_torque: f32,
        differential_ratio: f32,
    ) -> Self {
        let base = VehicleTrackConfiguration::new(driven_wheel, wheels);
        VehicleTrackConfiguration {
            inertia: inertia.max(0.001),
            angular_damping: angular_damping.max(0.0),
            max_brake_torque: max_brake_torque.max(0.0),
            differential_ratio: differential_ratio.max(0.001),
            ..base
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TrackedVehicleConfiguration {
    pub left_track: VehicleTrackConfiguration,
    pub right_track: VehicleTrackConfiguration,
    pub longitudinal_friction: f32,
    pub lateral_friction: f32,
}

impl TrackedVehicleConfiguration {
    pub fn new(
        left_track: VehicleTrackConfiguration,
        right_track: VehicleTrackConfiguration,
        longitudinal_friction: f32,
        lateral_friction: f32,
    ) -> Self {
        TrackedVehicleConfiguration {
            left_track,
            right_track,
            longitudinal_friction: longitudinal_friction.max(0.0),
            lateral_friction: lateral_friction.max(0.0),
        }
    }

    pub fn with_tracks(
        left_track: VehicleTrackConfiguration,
        right_track: VehicleTrackConfiguration,
    ) -> Self {
        TrackedVehicleConfiguration::new(left_track, right_track, 4.0, 2.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MotorcycleVehicleConfiguration {
    pub max_lean_angle: f32,
    pub lean_spring_constant: f32,
    pub lean_spring_damping: f32,
    pub lean_spring_integration_coefficient: f32,
    pub lean_spring_integration_coefficient_decay: f32,
    pub lean_smoothing_factor: f32,
    pub is_lean_controller_enabled: bool,
    pub is_lean_steering_limit_enabled: bool,
}

impl MotorcycleVehicleConfiguration {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        max_lean_angle: f32,
        lean_spring_constant: f32,
        lean_spring_damping: f32,
        lean_spring_integration_coefficient: f32,
        lean_spring_integration_coefficient_decay: f32,
        lean_smoothing_factor: f32,
        is_lean_controller_enabled: bool,
        is_lean_steering_limit_enabled: bool,
    ) -> Self {
        MotorcycleVehicleConfiguration {
            // Swift clamps lean angle into 0...pi/2.
            max_lean_angle: max_lean_angle.clamp(0.0, std::f32::consts::FRAC_PI_2),
            lean_spring_constant: lean_spring_constant.max(0.0),
            lean_spring_damping: lean_spring_damping.max(0.0),
            lean_spring_integration_coefficient: lean_spring_integration_coefficient.max(0.0),
            lean_spring_integration_coefficient_decay: lean_spring_integration_coefficient_decay
                .max(0.0),
            lean_smoothing_factor: lean_smoothing_factor.clamp(0.0, 1.0),
            is_lean_controller_enabled,
            is_lean_steering_limit_enabled,
        }
    }
}

impl Default for MotorcycleVehicleConfiguration {
    fn default() -> Self {
        MotorcycleVehicleConfiguration::new(
            std::f32::consts::FRAC_PI_4,
            5_000.0,
            1_000.0,
            0.0,
            4.0,
            0.8,
            true,
            true,
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum VehicleControllerConfiguration {
    #[default]
    Wheeled,
    Tracked(TrackedVehicleConfiguration),
    Motorcycle(MotorcycleVehicleConfiguration),
}

impl VehicleControllerConfiguration {
    pub fn kind(&self) -> VehicleControllerKind {
        match self {
            VehicleControllerConfiguration::Wheeled => VehicleControllerKind::Wheeled,
            VehicleControllerConfiguration::Tracked(_) => VehicleControllerKind::Tracked,
            VehicleControllerConfiguration::Motorcycle(_) => VehicleControllerKind::Motorcycle,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn motorcycle_clamps_lean_angle_and_smoothing() {
        let config =
            MotorcycleVehicleConfiguration::new(9.0, -1.0, -1.0, -1.0, -1.0, 5.0, true, false);
        assert_eq!(config.max_lean_angle, std::f32::consts::FRAC_PI_2);
        assert_eq!(config.lean_spring_constant, 0.0);
        assert_eq!(config.lean_smoothing_factor, 1.0);
        assert!(!config.is_lean_steering_limit_enabled);
    }

    #[test]
    fn motorcycle_defaults_match_swift() {
        let config = MotorcycleVehicleConfiguration::default();
        assert_eq!(config.max_lean_angle, std::f32::consts::FRAC_PI_4);
        assert_eq!(config.lean_spring_constant, 5_000.0);
        assert_eq!(config.lean_spring_damping, 1_000.0);
        assert_eq!(config.lean_spring_integration_coefficient_decay, 4.0);
        assert_eq!(config.lean_smoothing_factor, 0.8);
    }

    #[test]
    fn track_config_has_positive_floors() {
        let track = VehicleTrackConfiguration::with_wheels(2, vec![0, 1, 2], 0.0, -1.0, -1.0, 0.0);
        assert_eq!(track.inertia, 0.001);
        assert_eq!(track.angular_damping, 0.0);
        assert_eq!(track.max_brake_torque, 0.0);
        assert_eq!(track.differential_ratio, 0.001);
        assert_eq!(track.wheels, [0, 1, 2]);
    }

    #[test]
    fn track_config_pads_missing_wheels() {
        let track = VehicleTrackConfiguration::new(0, vec![7]);
        assert_eq!(track.wheels, [7, -1, -1]);
    }

    #[test]
    fn controller_kind_matches_variant() {
        assert_eq!(
            VehicleControllerConfiguration::default().kind(),
            VehicleControllerKind::Wheeled
        );
        assert_eq!(
            VehicleControllerConfiguration::Motorcycle(MotorcycleVehicleConfiguration::default())
                .kind(),
            VehicleControllerKind::Motorcycle
        );
    }

    #[test]
    fn controller_kind_round_trips() {
        for kind in VehicleControllerKind::ALL {
            assert_eq!(
                VehicleControllerKind::from_raw_value(kind.raw_value()),
                Some(kind)
            );
        }
        assert_eq!(VehicleControllerKind::from_raw_value(3), None);
    }
}
