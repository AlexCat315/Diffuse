//! Vehicle engine and transmission configuration.

use crate::physics::vehicles::vehicle_wheel_configuration::VehicleTransmissionMode;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleEngineConfiguration {
    pub max_torque: f32,
    pub min_rpm: f32,
    pub max_rpm: f32,
    pub inertia: f32,
    pub angular_damping: f32,
}

impl VehicleEngineConfiguration {
    pub fn new(
        max_torque: f32,
        min_rpm: f32,
        max_rpm: f32,
        inertia: f32,
        angular_damping: f32,
    ) -> Self {
        let min_rpm = min_rpm.max(0.0);
        VehicleEngineConfiguration {
            max_torque: max_torque.max(0.0),
            min_rpm,
            // Clamped against the already-clamped min.
            max_rpm: max_rpm.max(min_rpm),
            inertia: inertia.max(0.001),
            angular_damping: angular_damping.max(0.0),
        }
    }
}

impl Default for VehicleEngineConfiguration {
    fn default() -> Self {
        VehicleEngineConfiguration::new(500.0, 1_000.0, 6_000.0, 0.5, 0.2)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct VehicleTransmissionConfiguration {
    pub mode: VehicleTransmissionMode,
    pub gear_ratios: Vec<f32>,
    pub reverse_gear_ratios: Vec<f32>,
    pub switch_time: f32,
    pub clutch_release_time: f32,
    pub switch_latency: f32,
    pub shift_up_rpm: f32,
    pub shift_down_rpm: f32,
    pub clutch_strength: f32,
}

impl VehicleTransmissionConfiguration {
    /// Empty ratio lists fall back to `[1]` / `[-1]`; `shift_down_rpm` is clamped
    /// against the already-clamped `shift_up_rpm`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        mode: VehicleTransmissionMode,
        gear_ratios: Vec<f32>,
        reverse_gear_ratios: Vec<f32>,
        switch_time: f32,
        clutch_release_time: f32,
        switch_latency: f32,
        shift_up_rpm: f32,
        shift_down_rpm: f32,
        clutch_strength: f32,
    ) -> Self {
        let shift_up_rpm = shift_up_rpm.max(0.0);
        VehicleTransmissionConfiguration {
            mode,
            gear_ratios: if gear_ratios.is_empty() {
                vec![1.0]
            } else {
                gear_ratios
            },
            reverse_gear_ratios: if reverse_gear_ratios.is_empty() {
                vec![-1.0]
            } else {
                reverse_gear_ratios
            },
            switch_time: switch_time.max(0.0),
            clutch_release_time: clutch_release_time.max(0.0),
            switch_latency: switch_latency.max(0.0),
            shift_up_rpm,
            shift_down_rpm: shift_down_rpm.max(0.0).min(shift_up_rpm),
            clutch_strength: clutch_strength.max(0.0),
        }
    }
}

impl Default for VehicleTransmissionConfiguration {
    fn default() -> Self {
        VehicleTransmissionConfiguration::new(
            VehicleTransmissionMode::Automatic,
            vec![2.66, 1.78, 1.3, 1.0, 0.74],
            vec![-2.9],
            0.5,
            0.3,
            0.5,
            4_000.0,
            2_000.0,
            10.0,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_orders_rpm_range() {
        let engine = VehicleEngineConfiguration::new(500.0, 5_000.0, 1_000.0, 0.5, 0.2);
        assert_eq!(engine.min_rpm, 5_000.0);
        assert_eq!(engine.max_rpm, 5_000.0);
    }

    #[test]
    fn engine_inertia_has_positive_floor() {
        let engine = VehicleEngineConfiguration::new(-1.0, -1.0, -1.0, 0.0, -1.0);
        assert_eq!(engine.max_torque, 0.0);
        assert_eq!(engine.min_rpm, 0.0);
        assert_eq!(engine.inertia, 0.001);
        assert_eq!(engine.angular_damping, 0.0);
    }

    #[test]
    fn empty_gear_lists_get_unit_fallbacks() {
        let transmission = VehicleTransmissionConfiguration::new(
            VehicleTransmissionMode::Manual,
            Vec::new(),
            Vec::new(),
            0.5,
            0.3,
            0.5,
            4_000.0,
            2_000.0,
            10.0,
        );
        assert_eq!(transmission.gear_ratios, vec![1.0]);
        assert_eq!(transmission.reverse_gear_ratios, vec![-1.0]);
    }

    #[test]
    fn shift_down_rpm_clamps_against_shift_up() {
        let transmission = VehicleTransmissionConfiguration::new(
            VehicleTransmissionMode::Automatic,
            vec![1.0],
            vec![-1.0],
            0.5,
            0.3,
            0.5,
            2_000.0,
            9_000.0,
            10.0,
        );
        assert_eq!(transmission.shift_up_rpm, 2_000.0);
        assert_eq!(transmission.shift_down_rpm, 2_000.0);
    }

    #[test]
    fn default_transmission_matches_swift() {
        let transmission = VehicleTransmissionConfiguration::default();
        assert_eq!(transmission.gear_ratios, vec![2.66, 1.78, 1.3, 1.0, 0.74]);
        assert_eq!(transmission.reverse_gear_ratios, vec![-2.9]);
        assert_eq!(transmission.shift_up_rpm, 4_000.0);
        assert_eq!(transmission.clutch_strength, 10.0);
    }
}
