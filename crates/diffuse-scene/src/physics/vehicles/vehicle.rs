//! The authored `Vehicle` component and its convenience presets.

use diffuse_math::simd::simd_compat::Float3;

use crate::entity_id::RuntimeComponent;
use crate::physics::vehicles::vehicle_controller_configuration::{
    MotorcycleVehicleConfiguration, TrackedVehicleConfiguration, VehicleControllerConfiguration,
    VehicleTrackConfiguration,
};
use crate::physics::vehicles::vehicle_powertrain::{
    VehicleEngineConfiguration, VehicleTransmissionConfiguration,
};
use crate::physics::vehicles::vehicle_wheel_configuration::{
    VehicleAntiRollBarConfiguration, VehicleDifferentialConfiguration, VehicleWheelConfiguration,
};

/// A backend-simulated vehicle attached to the same entity's dynamic `RigidBody`.
#[derive(Clone, Debug, PartialEq)]
pub struct Vehicle {
    pub controller: VehicleControllerConfiguration,
    pub wheels: Vec<VehicleWheelConfiguration>,
    pub differentials: Vec<VehicleDifferentialConfiguration>,
    pub anti_roll_bars: Vec<VehicleAntiRollBarConfiguration>,
    pub engine: VehicleEngineConfiguration,
    pub transmission: VehicleTransmissionConfiguration,
    pub up: Float3,
    pub forward: Float3,
    pub max_pitch_roll_angle: f32,
    pub is_enabled: bool,
}

impl Vehicle {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        controller: VehicleControllerConfiguration,
        wheels: Vec<VehicleWheelConfiguration>,
        differentials: Vec<VehicleDifferentialConfiguration>,
        anti_roll_bars: Vec<VehicleAntiRollBarConfiguration>,
        engine: VehicleEngineConfiguration,
        transmission: VehicleTransmissionConfiguration,
        up: Float3,
        forward: Float3,
        max_pitch_roll_angle: f32,
        is_enabled: bool,
    ) -> Self {
        Vehicle {
            controller,
            wheels,
            differentials,
            anti_roll_bars,
            engine,
            transmission,
            up,
            forward,
            max_pitch_roll_angle: max_pitch_roll_angle.clamp(0.0, std::f32::consts::PI),
            is_enabled,
        }
    }

    /// `static let defaultWheels` — four wheels, front pair steerable, rear pair
    /// with hand-brake torque.
    pub fn default_wheels() -> Vec<VehicleWheelConfiguration> {
        vec![
            with_steer(
                VehicleWheelConfiguration::at_position(Float3::new(0.9, -0.2, 1.4)),
                std::f32::consts::FRAC_PI_4,
            ),
            with_steer(
                VehicleWheelConfiguration::at_position(Float3::new(-0.9, -0.2, 1.4)),
                std::f32::consts::FRAC_PI_4,
            ),
            with_hand_brake(
                VehicleWheelConfiguration::at_position(Float3::new(0.9, -0.2, -1.4)),
                4_000.0,
            ),
            with_hand_brake(
                VehicleWheelConfiguration::at_position(Float3::new(-0.9, -0.2, -1.4)),
                4_000.0,
            ),
        ]
    }

    /// The default wheeled vehicle.
    pub fn wheeled() -> Self {
        Vehicle::new(
            VehicleControllerConfiguration::Wheeled,
            Vehicle::default_wheels(),
            vec![VehicleDifferentialConfiguration::new(2, 3).validated()],
            vec![
                VehicleAntiRollBarConfiguration::new(0, 1).validated(),
                VehicleAntiRollBarConfiguration::new(2, 3).validated(),
            ],
            VehicleEngineConfiguration::default(),
            VehicleTransmissionConfiguration::default(),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            std::f32::consts::PI,
            true,
        )
    }

    /// `static func tracked(engine:transmission:)`.
    pub fn tracked(
        engine: VehicleEngineConfiguration,
        transmission: VehicleTransmissionConfiguration,
    ) -> Self {
        let wheels = vec![
            wide(Float3::new(0.9, -0.25, 1.2)),
            wide(Float3::new(0.9, -0.25, 0.0)),
            wide(Float3::new(0.9, -0.25, -1.2)),
            wide(Float3::new(-0.9, -0.25, 1.2)),
            wide(Float3::new(-0.9, -0.25, 0.0)),
            wide(Float3::new(-0.9, -0.25, -1.2)),
        ];
        let tracked = TrackedVehicleConfiguration::with_tracks(
            VehicleTrackConfiguration::new(2, vec![0, 1, 2]),
            VehicleTrackConfiguration::new(5, vec![3, 4, 5]),
        );
        Vehicle::new(
            VehicleControllerConfiguration::Tracked(tracked),
            wheels,
            Vec::new(),
            Vec::new(),
            engine,
            transmission,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            std::f32::consts::FRAC_PI_3,
            true,
        )
    }

    /// `static func tracked()` with Swift's default engine and transmission.
    pub fn tracked_default() -> Self {
        Vehicle::tracked(
            VehicleEngineConfiguration::new(1_500.0, 1_000.0, 6_000.0, 0.5, 0.2),
            VehicleTransmissionConfiguration::default(),
        )
    }

    /// `static func motorcycle(configuration:engine:transmission:)`.
    pub fn motorcycle(
        configuration: MotorcycleVehicleConfiguration,
        engine: VehicleEngineConfiguration,
        transmission: VehicleTransmissionConfiguration,
    ) -> Self {
        let mut front = VehicleWheelConfiguration::at_position(Float3::new(0.0, -0.25, 0.75));
        front.suspension_direction = Float3::new(0.0, -0.866_025_4, 0.5);
        front.steering_axis = Float3::new(0.0, 0.866_025_4, -0.5);
        front.suspension_min_length = 0.3;
        front.suspension_max_length = 0.5;
        front.suspension_frequency = 1.5;
        front.radius = 0.31;
        front.width = 0.08;
        front.max_steer_angle = std::f32::consts::FRAC_PI_6;
        front.max_brake_torque = 500.0;
        let front = rebuild(front);

        let mut rear = VehicleWheelConfiguration::at_position(Float3::new(0.0, -0.25, -0.75));
        rear.suspension_min_length = 0.3;
        rear.suspension_max_length = 0.5;
        rear.suspension_frequency = 2.0;
        rear.radius = 0.31;
        rear.width = 0.08;
        rear.max_brake_torque = 250.0;
        let rear = rebuild(rear);

        let mut differential = VehicleDifferentialConfiguration::new(-1, 1);
        differential.differential_ratio = 4.825;
        Vehicle::new(
            VehicleControllerConfiguration::Motorcycle(configuration),
            vec![front, rear],
            vec![differential.validated()],
            Vec::new(),
            engine,
            transmission,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            std::f32::consts::FRAC_PI_3,
            true,
        )
    }

    /// `static func motorcycle()` with Swift's defaults.
    pub fn motorcycle_default() -> Self {
        Vehicle::motorcycle(
            MotorcycleVehicleConfiguration::default(),
            VehicleEngineConfiguration::new(150.0, 1_000.0, 10_000.0, 0.5, 0.2),
            VehicleTransmissionConfiguration::new(
                crate::physics::vehicles::vehicle_wheel_configuration::VehicleTransmissionMode::Automatic,
                vec![2.27, 1.63, 1.3, 1.09, 0.96, 0.88],
                vec![-4.0],
                0.5,
                0.3,
                0.5,
                8_000.0,
                2_000.0,
                2.0,
            ),
        )
    }
}

impl Default for Vehicle {
    fn default() -> Self {
        Vehicle::wheeled()
    }
}

impl RuntimeComponent for Vehicle {}

/// Re-runs the clamping initializer on a wheel whose fields were mutated in place.
fn rebuild(wheel: VehicleWheelConfiguration) -> VehicleWheelConfiguration {
    VehicleWheelConfiguration::new(
        wheel.position,
        wheel.suspension_direction,
        wheel.steering_axis,
        wheel.wheel_up,
        wheel.wheel_forward,
        wheel.suspension_min_length,
        wheel.suspension_max_length,
        wheel.suspension_preload_length,
        wheel.suspension_frequency,
        wheel.suspension_damping,
        wheel.radius,
        wheel.width,
        wheel.inertia,
        wheel.angular_damping,
        wheel.max_steer_angle,
        wheel.max_brake_torque,
        wheel.max_hand_brake_torque,
    )
}

fn with_steer(
    mut wheel: VehicleWheelConfiguration,
    max_steer_angle: f32,
) -> VehicleWheelConfiguration {
    wheel.max_steer_angle = max_steer_angle;
    rebuild(wheel)
}

fn with_hand_brake(
    mut wheel: VehicleWheelConfiguration,
    max_hand_brake_torque: f32,
) -> VehicleWheelConfiguration {
    wheel.max_hand_brake_torque = max_hand_brake_torque;
    rebuild(wheel)
}

fn wide(position: Float3) -> VehicleWheelConfiguration {
    let mut wheel = VehicleWheelConfiguration::at_position(position);
    wheel.width = 0.35;
    rebuild(wheel)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wheeled_has_four_wheels_and_two_anti_roll_bars() {
        let vehicle = Vehicle::wheeled();
        assert_eq!(vehicle.wheels.len(), 4);
        assert_eq!(vehicle.anti_roll_bars.len(), 2);
        assert_eq!(vehicle.differentials.len(), 1);
        assert_eq!(vehicle.controller, VehicleControllerConfiguration::Wheeled);
    }

    #[test]
    fn front_wheels_steer_and_rear_wheels_hand_brake() {
        let wheels = Vehicle::default_wheels();
        assert_eq!(wheels[0].max_steer_angle, std::f32::consts::FRAC_PI_4);
        assert_eq!(wheels[1].max_steer_angle, std::f32::consts::FRAC_PI_4);
        assert_eq!(wheels[2].max_hand_brake_torque, 4_000.0);
        assert_eq!(wheels[3].max_hand_brake_torque, 4_000.0);
        assert_eq!(wheels[0].max_hand_brake_torque, 0.0);
    }

    #[test]
    fn max_pitch_roll_angle_clamps_to_pi() {
        let vehicle = Vehicle::new(
            VehicleControllerConfiguration::Wheeled,
            Vec::new(),
            Vec::new(),
            Vec::new(),
            VehicleEngineConfiguration::default(),
            VehicleTransmissionConfiguration::default(),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            9.0,
            true,
        );
        assert_eq!(vehicle.max_pitch_roll_angle, std::f32::consts::PI);
    }

    #[test]
    fn tracked_has_six_wide_wheels_and_no_differentials() {
        let vehicle = Vehicle::tracked_default();
        assert_eq!(vehicle.wheels.len(), 6);
        assert_eq!(vehicle.wheels[0].width, 0.35);
        assert!(vehicle.differentials.is_empty());
        assert!(vehicle.anti_roll_bars.is_empty());
        assert_eq!(vehicle.engine.max_torque, 1_500.0);
        assert_eq!(vehicle.max_pitch_roll_angle, std::f32::consts::FRAC_PI_3);
        match &vehicle.controller {
            VehicleControllerConfiguration::Tracked(tracked) => {
                assert_eq!(tracked.left_track.wheels, [0, 1, 2]);
                assert_eq!(tracked.right_track.wheels, [3, 4, 5]);
                assert_eq!(tracked.left_track.driven_wheel, 2);
                assert_eq!(tracked.right_track.driven_wheel, 5);
            }
            _ => panic!("expected tracked controller"),
        }
    }

    #[test]
    fn motorcycle_has_two_wheels_and_tilted_suspension() {
        let vehicle = Vehicle::motorcycle_default();
        assert_eq!(vehicle.wheels.len(), 2);
        assert_eq!(vehicle.wheels[0].position, Float3::new(0.0, -0.25, 0.75));
        assert_eq!(
            vehicle.wheels[0].suspension_direction,
            Float3::new(0.0, -0.866_025_4, 0.5)
        );
        assert_eq!(
            vehicle.wheels[0].steering_axis,
            Float3::new(0.0, 0.866_025_4, -0.5)
        );
        assert_eq!(vehicle.wheels[0].max_brake_torque, 500.0);
        assert_eq!(vehicle.wheels[1].max_brake_torque, 250.0);
        assert_eq!(vehicle.differentials[0].differential_ratio, 4.825);
        assert_eq!(vehicle.transmission.shift_up_rpm, 8_000.0);
        assert_eq!(vehicle.transmission.clutch_strength, 2.0);
    }

    #[test]
    fn default_vehicle_is_the_wheeled_preset() {
        assert_eq!(Vehicle::default(), Vehicle::wheeled());
    }
}
