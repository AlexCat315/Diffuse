//! Joint configuration payloads.
//!
//! Every nested struct clamps in its initializer exactly like Swift; the clamps are
//! order-sensitive (several read an already-clamped sibling), so they are applied
//! in declaration order.

use diffuse_math::simd::simd_compat::{Float3, simd_max, simd_min};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicsJointKind {
    PointToPoint,
    Hinge,
    Fixed,
    Slider,
    Distance,
    Cone,
    SixDof,
}

impl PhysicsJointKind {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            PhysicsJointKind::PointToPoint => "pointToPoint",
            PhysicsJointKind::Hinge => "hinge",
            PhysicsJointKind::Fixed => "fixed",
            PhysicsJointKind::Slider => "slider",
            PhysicsJointKind::Distance => "distance",
            PhysicsJointKind::Cone => "cone",
            PhysicsJointKind::SixDof => "sixDOF",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "pointToPoint" => Some(PhysicsJointKind::PointToPoint),
            "hinge" => Some(PhysicsJointKind::Hinge),
            "fixed" => Some(PhysicsJointKind::Fixed),
            "slider" => Some(PhysicsJointKind::Slider),
            "distance" => Some(PhysicsJointKind::Distance),
            "cone" => Some(PhysicsJointKind::Cone),
            "sixDOF" => Some(PhysicsJointKind::SixDof),
            _ => None,
        }
    }

    pub const ALL: [PhysicsJointKind; 7] = [
        PhysicsJointKind::PointToPoint,
        PhysicsJointKind::Hinge,
        PhysicsJointKind::Fixed,
        PhysicsJointKind::Slider,
        PhysicsJointKind::Distance,
        PhysicsJointKind::Cone,
        PhysicsJointKind::SixDof,
    ];
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PhysicsJointSpring {
    pub frequency: f32,
    pub damping: f32,
}

impl PhysicsJointSpring {
    pub fn new(frequency: f32, damping: f32) -> Self {
        PhysicsJointSpring {
            frequency: frequency.max(0.0),
            damping: damping.max(0.0),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicsJointMotorMode {
    Disabled,
    Position,
    Velocity,
}

impl PhysicsJointMotorMode {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            PhysicsJointMotorMode::Disabled => "disabled",
            PhysicsJointMotorMode::Position => "position",
            PhysicsJointMotorMode::Velocity => "velocity",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "disabled" => Some(PhysicsJointMotorMode::Disabled),
            "position" => Some(PhysicsJointMotorMode::Position),
            "velocity" => Some(PhysicsJointMotorMode::Velocity),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsJointMotor {
    pub mode: PhysicsJointMotorMode,
    pub target_position: f32,
    pub target_velocity: f32,
    pub max_force: f32,
}

impl PhysicsJointMotor {
    pub const DEFAULT_MAX_FORCE: f32 = f32::MAX;

    pub fn new(
        mode: PhysicsJointMotorMode,
        target_position: f32,
        target_velocity: f32,
        max_force: f32,
    ) -> Self {
        PhysicsJointMotor {
            mode,
            target_position,
            target_velocity,
            max_force: max_force.max(0.0),
        }
    }
}

impl Default for PhysicsJointMotor {
    fn default() -> Self {
        PhysicsJointMotor {
            mode: PhysicsJointMotorMode::Disabled,
            target_position: 0.0,
            target_velocity: 0.0,
            max_force: PhysicsJointMotor::DEFAULT_MAX_FORCE,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DistanceJointConfiguration {
    pub minimum_distance: f32,
    pub maximum_distance: f32,
    pub spring: PhysicsJointSpring,
}

impl DistanceJointConfiguration {
    pub fn new(minimum_distance: f32, maximum_distance: f32, spring: PhysicsJointSpring) -> Self {
        let minimum = minimum_distance.max(0.0);
        DistanceJointConfiguration {
            minimum_distance: minimum,
            maximum_distance: maximum_distance.max(minimum),
            spring,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HingeJointConfiguration {
    pub axis_a: Float3,
    pub axis_b: Float3,
    pub minimum_angle: f32,
    pub maximum_angle: f32,
    pub motor: PhysicsJointMotor,
    pub spring: PhysicsJointSpring,
}

impl HingeJointConfiguration {
    pub fn new(
        axis_a: Float3,
        axis_b: Float3,
        minimum_angle: f32,
        maximum_angle: f32,
        motor: PhysicsJointMotor,
        spring: PhysicsJointSpring,
    ) -> Self {
        HingeJointConfiguration {
            axis_a,
            axis_b,
            minimum_angle: minimum_angle.min(maximum_angle),
            maximum_angle: minimum_angle.max(maximum_angle),
            motor,
            spring,
        }
    }
}

impl Default for HingeJointConfiguration {
    fn default() -> Self {
        HingeJointConfiguration::new(
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            0.0,
            0.0,
            PhysicsJointMotor::default(),
            PhysicsJointSpring::default(),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SliderJointConfiguration {
    pub axis_a: Float3,
    pub axis_b: Float3,
    pub minimum_distance: f32,
    pub maximum_distance: f32,
    pub motor: PhysicsJointMotor,
    pub spring: PhysicsJointSpring,
}

impl SliderJointConfiguration {
    pub fn new(
        axis_a: Float3,
        axis_b: Float3,
        minimum_distance: f32,
        maximum_distance: f32,
        motor: PhysicsJointMotor,
        spring: PhysicsJointSpring,
    ) -> Self {
        SliderJointConfiguration {
            axis_a,
            axis_b,
            minimum_distance: minimum_distance.min(maximum_distance),
            maximum_distance: minimum_distance.max(maximum_distance),
            motor,
            spring,
        }
    }
}

impl Default for SliderJointConfiguration {
    fn default() -> Self {
        SliderJointConfiguration::new(
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            0.0,
            0.0,
            PhysicsJointMotor::default(),
            PhysicsJointSpring::default(),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ConeJointConfiguration {
    pub twist_axis_a: Float3,
    pub twist_axis_b: Float3,
    pub half_cone_angle: f32,
    pub minimum_twist_angle: f32,
    pub maximum_twist_angle: f32,
    pub spring: PhysicsJointSpring,
}

impl ConeJointConfiguration {
    pub fn new(
        twist_axis_a: Float3,
        twist_axis_b: Float3,
        half_cone_angle: f32,
        minimum_twist_angle: f32,
        maximum_twist_angle: f32,
        spring: PhysicsJointSpring,
    ) -> Self {
        ConeJointConfiguration {
            twist_axis_a,
            twist_axis_b,
            half_cone_angle: half_cone_angle.max(0.0),
            minimum_twist_angle: minimum_twist_angle.min(maximum_twist_angle),
            maximum_twist_angle: minimum_twist_angle.max(maximum_twist_angle),
            spring,
        }
    }
}

impl Default for ConeJointConfiguration {
    fn default() -> Self {
        ConeJointConfiguration::new(
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            std::f32::consts::FRAC_PI_4,
            -std::f32::consts::PI,
            std::f32::consts::PI,
            PhysicsJointSpring::default(),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SixDofJointConfiguration {
    pub axis_a: Float3,
    pub axis_b: Float3,
    pub linear_minimum: Float3,
    pub linear_maximum: Float3,
    pub angular_minimum: Float3,
    pub angular_maximum: Float3,
    pub linear_motor: PhysicsJointMotor,
    pub angular_motor: PhysicsJointMotor,
    pub spring: PhysicsJointSpring,
}

impl SixDofJointConfiguration {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        axis_a: Float3,
        axis_b: Float3,
        linear_minimum: Float3,
        linear_maximum: Float3,
        angular_minimum: Float3,
        angular_maximum: Float3,
        linear_motor: PhysicsJointMotor,
        angular_motor: PhysicsJointMotor,
        spring: PhysicsJointSpring,
    ) -> Self {
        SixDofJointConfiguration {
            axis_a,
            axis_b,
            linear_minimum: simd_min(linear_minimum, linear_maximum),
            linear_maximum: simd_max(linear_minimum, linear_maximum),
            angular_minimum: simd_min(angular_minimum, angular_maximum),
            angular_maximum: simd_max(angular_minimum, angular_maximum),
            linear_motor,
            angular_motor,
            spring,
        }
    }
}

impl Default for SixDofJointConfiguration {
    fn default() -> Self {
        SixDofJointConfiguration::new(
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::ZERO,
            Float3::ZERO,
            Float3::ZERO,
            Float3::ZERO,
            PhysicsJointMotor::default(),
            PhysicsJointMotor::default(),
            PhysicsJointSpring::default(),
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum PhysicsJointConfiguration {
    #[default]
    Point,
    Fixed {
        axis_a: Float3,
        axis_b: Float3,
    },
    Distance(DistanceJointConfiguration),
    Hinge(HingeJointConfiguration),
    Slider(SliderJointConfiguration),
    Cone(ConeJointConfiguration),
    SixDof(SixDofJointConfiguration),
}

impl PhysicsJointConfiguration {
    pub fn kind(&self) -> PhysicsJointKind {
        match self {
            PhysicsJointConfiguration::Point => PhysicsJointKind::PointToPoint,
            PhysicsJointConfiguration::Fixed { .. } => PhysicsJointKind::Fixed,
            PhysicsJointConfiguration::Distance(_) => PhysicsJointKind::Distance,
            PhysicsJointConfiguration::Hinge(_) => PhysicsJointKind::Hinge,
            PhysicsJointConfiguration::Slider(_) => PhysicsJointKind::Slider,
            PhysicsJointConfiguration::Cone(_) => PhysicsJointKind::Cone,
            PhysicsJointConfiguration::SixDof(_) => PhysicsJointKind::SixDof,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joint_kind_round_trips_raw_values() {
        for kind in PhysicsJointKind::ALL {
            assert_eq!(
                PhysicsJointKind::from_raw_value(kind.raw_value()),
                Some(kind)
            );
        }
        assert_eq!(PhysicsJointKind::SixDof.raw_value(), "sixDOF");
    }

    #[test]
    fn distance_clamps_minimum_then_widens_maximum() {
        // Swift: minimum = max(0, min); maximum = max(minimum, maximum).
        let config = DistanceJointConfiguration::new(-5.0, -1.0, PhysicsJointSpring::default());
        assert_eq!(config.minimum_distance, 0.0);
        assert_eq!(config.maximum_distance, 0.0);
    }

    #[test]
    fn hinge_orders_angle_limits() {
        let config = HingeJointConfiguration::new(
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            2.0,
            -1.0,
            PhysicsJointMotor::default(),
            PhysicsJointSpring::default(),
        );
        assert_eq!(config.minimum_angle, -1.0);
        assert_eq!(config.maximum_angle, 2.0);
    }

    #[test]
    fn six_dof_orders_component_limits() {
        let config = SixDofJointConfiguration::new(
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(3.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::ZERO,
            Float3::ZERO,
            PhysicsJointMotor::default(),
            PhysicsJointMotor::default(),
            PhysicsJointSpring::default(),
        );
        assert_eq!(config.linear_minimum, Float3::new(1.0, 0.0, 0.0));
        assert_eq!(config.linear_maximum, Float3::new(3.0, 0.0, 0.0));
    }

    #[test]
    fn motor_max_force_defaults_to_greatest_finite_magnitude() {
        assert_eq!(PhysicsJointMotor::default().max_force, f32::MAX);
        assert_eq!(
            PhysicsJointMotor::new(PhysicsJointMotorMode::Disabled, 0.0, 0.0, -3.0).max_force,
            0.0
        );
    }

    #[test]
    fn configuration_kind_matches_variant() {
        assert_eq!(
            PhysicsJointConfiguration::Point.kind(),
            PhysicsJointKind::PointToPoint
        );
        assert_eq!(
            PhysicsJointConfiguration::SixDof(SixDofJointConfiguration::default()).kind(),
            PhysicsJointKind::SixDof
        );
    }
}
