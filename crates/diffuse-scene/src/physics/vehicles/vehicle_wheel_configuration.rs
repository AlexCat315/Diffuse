//! Vehicle wheel, differential and anti-roll-bar configuration.

use diffuse_math::simd::simd_compat::Float3;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum VehicleTransmissionMode {
    #[default]
    Automatic,
    Manual,
}

impl VehicleTransmissionMode {
    /// `UInt8`-backed and `Codable`.
    pub const fn raw_value(&self) -> u8 {
        match self {
            VehicleTransmissionMode::Automatic => 0,
            VehicleTransmissionMode::Manual => 1,
        }
    }

    pub const fn from_raw_value(value: u8) -> Option<Self> {
        match value {
            0 => Some(VehicleTransmissionMode::Automatic),
            1 => Some(VehicleTransmissionMode::Manual),
            _ => None,
        }
    }
}

impl serde::Serialize for VehicleTransmissionMode {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u8(self.raw_value())
    }
}

impl<'de> serde::Deserialize<'de> for VehicleTransmissionMode {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = u8::deserialize(deserializer)?;
        VehicleTransmissionMode::from_raw_value(value)
            .ok_or_else(|| serde::de::Error::custom(format!("Unknown transmission mode: {value}")))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleWheelConfiguration {
    pub position: Float3,
    pub suspension_direction: Float3,
    pub steering_axis: Float3,
    pub wheel_up: Float3,
    pub wheel_forward: Float3,
    pub suspension_min_length: f32,
    pub suspension_max_length: f32,
    pub suspension_preload_length: f32,
    pub suspension_frequency: f32,
    pub suspension_damping: f32,
    pub radius: f32,
    pub width: f32,
    pub inertia: f32,
    pub angular_damping: f32,
    pub max_steer_angle: f32,
    pub max_brake_torque: f32,
    pub max_hand_brake_torque: f32,
}

impl VehicleWheelConfiguration {
    /// Swift's memberwise `init` with all sixteen parameters and its clamping
    /// rules applied in declaration order.
    ///
    /// `suspension_min_length` is clamped against the *incoming* max first, then
    /// `suspension_max_length` is raised to at least the clamped min.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        position: Float3,
        suspension_direction: Float3,
        steering_axis: Float3,
        wheel_up: Float3,
        wheel_forward: Float3,
        suspension_min_length: f32,
        suspension_max_length: f32,
        suspension_preload_length: f32,
        suspension_frequency: f32,
        suspension_damping: f32,
        radius: f32,
        width: f32,
        inertia: f32,
        angular_damping: f32,
        max_steer_angle: f32,
        max_brake_torque: f32,
        max_hand_brake_torque: f32,
    ) -> Self {
        let min_length = suspension_min_length.max(0.0).min(suspension_max_length);
        VehicleWheelConfiguration {
            position,
            suspension_direction,
            steering_axis,
            wheel_up,
            wheel_forward,
            suspension_min_length: min_length,
            suspension_max_length: suspension_max_length.max(min_length),
            suspension_preload_length: suspension_preload_length.max(0.0),
            suspension_frequency: suspension_frequency.max(0.0),
            suspension_damping: suspension_damping.max(0.0),
            radius: radius.max(0.01),
            width: width.max(0.01),
            inertia: inertia.max(0.001),
            angular_damping: angular_damping.max(0.0),
            max_steer_angle: max_steer_angle.max(0.0),
            max_brake_torque: max_brake_torque.max(0.0),
            max_hand_brake_torque: max_hand_brake_torque.max(0.0),
        }
    }

    /// The Swift default for every parameter except `position`.
    pub fn at_position(position: Float3) -> Self {
        VehicleWheelConfiguration::new(
            position,
            Float3::new(0.0, -1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            0.2,
            0.5,
            0.0,
            1.5,
            0.5,
            0.35,
            0.2,
            0.9,
            0.2,
            0.0,
            1_500.0,
            0.0,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleDifferentialConfiguration {
    pub left_wheel: i64,
    pub right_wheel: i64,
    pub differential_ratio: f32,
    pub left_right_split: f32,
    pub limited_slip_ratio: f32,
    pub engine_torque_ratio: f32,
}

impl VehicleDifferentialConfiguration {
    pub fn new(left_wheel: i64, right_wheel: i64) -> Self {
        VehicleDifferentialConfiguration {
            left_wheel,
            right_wheel,
            differential_ratio: 3.42,
            left_right_split: 0.5,
            limited_slip_ratio: 1.4,
            engine_torque_ratio: 1.0,
        }
    }

    pub fn validated(self) -> Self {
        VehicleDifferentialConfiguration {
            left_wheel: self.left_wheel,
            right_wheel: self.right_wheel,
            differential_ratio: self.differential_ratio.max(0.001),
            left_right_split: self.left_right_split.clamp(0.0, 1.0),
            // Strictly greater than 1: Swift uses `max(1.0001, ...)`.
            limited_slip_ratio: self.limited_slip_ratio.max(1.0001),
            engine_torque_ratio: self.engine_torque_ratio.max(0.0),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleAntiRollBarConfiguration {
    pub left_wheel: i64,
    pub right_wheel: i64,
    pub stiffness: f32,
}

impl VehicleAntiRollBarConfiguration {
    pub fn new(left_wheel: i64, right_wheel: i64) -> Self {
        VehicleAntiRollBarConfiguration {
            left_wheel,
            right_wheel,
            stiffness: 1_000.0,
        }
    }

    pub fn validated(self) -> Self {
        VehicleAntiRollBarConfiguration {
            left_wheel: self.left_wheel,
            right_wheel: self.right_wheel,
            stiffness: self.stiffness.max(0.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> VehicleWheelConfiguration {
        VehicleWheelConfiguration::at_position(Float3::ZERO)
    }

    #[test]
    fn defaults_match_swift_memberwise_init() {
        let wheel = base();
        assert_eq!(wheel.suspension_min_length, 0.2);
        assert_eq!(wheel.suspension_max_length, 0.5);
        assert_eq!(wheel.radius, 0.35);
        assert_eq!(wheel.width, 0.2);
        assert_eq!(wheel.max_brake_torque, 1_500.0);
        assert_eq!(wheel.max_steer_angle, 0.0);
        assert_eq!(wheel.suspension_direction, Float3::new(0.0, -1.0, 0.0));
    }

    #[test]
    fn suspension_clamps_min_against_incoming_max_then_raises_max() {
        let mut params = base();
        params.suspension_min_length = 0.9;
        params.suspension_max_length = 0.4;
        let wheel = VehicleWheelConfiguration::new(
            params.position,
            params.suspension_direction,
            params.steering_axis,
            params.wheel_up,
            params.wheel_forward,
            params.suspension_min_length,
            params.suspension_max_length,
            params.suspension_preload_length,
            params.suspension_frequency,
            params.suspension_damping,
            params.radius,
            params.width,
            params.inertia,
            params.angular_damping,
            params.max_steer_angle,
            params.max_brake_torque,
            params.max_hand_brake_torque,
        );
        // min = max(0, min(0.4, 0.9)) = 0.4, then max = max(0.4, 0.4) = 0.4.
        assert_eq!(wheel.suspension_min_length, 0.4);
        assert_eq!(wheel.suspension_max_length, 0.4);
    }

    #[test]
    fn wheel_dimensions_have_positive_floors() {
        let wheel = VehicleWheelConfiguration::new(
            Float3::ZERO,
            Float3::new(0.0, -1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            0.2,
            0.5,
            0.0,
            1.5,
            0.5,
            0.0,
            -1.0,
            0.0,
            0.2,
            0.0,
            1_500.0,
            0.0,
        );
        assert_eq!(wheel.radius, 0.01);
        assert_eq!(wheel.width, 0.01);
        assert_eq!(wheel.inertia, 0.001);
    }

    #[test]
    fn limited_slip_ratio_stays_above_one() {
        let mut differential = VehicleDifferentialConfiguration::new(0, 1);
        differential.limited_slip_ratio = 0.5;
        assert_eq!(differential.validated().limited_slip_ratio, 1.0001);
    }

    #[test]
    fn differential_split_clamps_into_unit_range() {
        let mut differential = VehicleDifferentialConfiguration::new(0, 1);
        differential.left_right_split = 4.0;
        assert_eq!(differential.validated().left_right_split, 1.0);
    }

    #[test]
    fn transmission_mode_round_trips() {
        assert_eq!(VehicleTransmissionMode::Manual.raw_value(), 1);
        assert_eq!(
            VehicleTransmissionMode::from_raw_value(0),
            Some(VehicleTransmissionMode::Automatic)
        );
        assert_eq!(VehicleTransmissionMode::from_raw_value(7), None);
        assert_eq!(
            VehicleTransmissionMode::default(),
            VehicleTransmissionMode::Automatic
        );
    }
}
