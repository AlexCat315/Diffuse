//! Authored joint state.
//!
//! Swift keeps a typed `configuration` plus a family of computed accessors that
//! project the "primary axes" and "scalar limits" out of the active variant. The
//! setters mutate the variant in place, so writing `axis_a` on a hinge preserves
//! the other hinge fields.

use diffuse_math::simd::simd_compat::Float3;

use crate::entity_id::{EntityID, RuntimeComponent};
use crate::physics::joints::physics_joint_configuration::{
    ConeJointConfiguration, DistanceJointConfiguration, HingeJointConfiguration,
    PhysicsJointConfiguration, PhysicsJointKind, PhysicsJointMotor, PhysicsJointSpring,
    SixDofJointConfiguration, SliderJointConfiguration,
};

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsJoint {
    pub configuration: PhysicsJointConfiguration,
    pub entity_a: EntityID,
    pub entity_b: EntityID,
    pub pivot_a: Float3,
    pub pivot_b: Float3,
    pub is_enabled: bool,
    pub break_force: f32,
    pub break_torque: f32,
}

impl PhysicsJoint {
    /// Swift's `breakForce`/`breakTorque` default to `.greatestFiniteMagnitude`.
    pub const DEFAULT_BREAK_LIMIT: f32 = f32::MAX;

    /// `init(configuration:entityA:entityB:pivotA:pivotB:isEnabled:breakForce:breakTorque:)`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        configuration: PhysicsJointConfiguration,
        entity_a: EntityID,
        entity_b: EntityID,
        pivot_a: Float3,
        pivot_b: Float3,
        is_enabled: bool,
        break_force: f32,
        break_torque: f32,
    ) -> Self {
        PhysicsJoint {
            configuration,
            entity_a,
            entity_b,
            pivot_a,
            pivot_b,
            is_enabled,
            break_force: break_force.max(0.0),
            break_torque: break_torque.max(0.0),
        }
    }

    /// Compatibility initializer for Physics v1 callers, which described the joint
    /// with a kind plus generic axes and scalar limits.
    #[allow(clippy::too_many_arguments)]
    pub fn from_kind(
        constraint_type: PhysicsJointKind,
        entity_a: EntityID,
        entity_b: EntityID,
        pivot_a: Float3,
        pivot_b: Float3,
        axis_a: Float3,
        axis_b: Float3,
        min_limit: f32,
        max_limit: f32,
        is_enabled: bool,
        break_force: f32,
        break_torque: f32,
    ) -> Self {
        let configuration = match constraint_type {
            PhysicsJointKind::PointToPoint => PhysicsJointConfiguration::Point,
            PhysicsJointKind::Fixed => PhysicsJointConfiguration::Fixed { axis_a, axis_b },
            PhysicsJointKind::Distance => {
                PhysicsJointConfiguration::Distance(DistanceJointConfiguration::new(
                    min_limit,
                    max_limit,
                    PhysicsJointSpring::default(),
                ))
            }
            PhysicsJointKind::Hinge => {
                PhysicsJointConfiguration::Hinge(HingeJointConfiguration::new(
                    axis_a,
                    axis_b,
                    min_limit,
                    max_limit,
                    PhysicsJointMotor::default(),
                    PhysicsJointSpring::default(),
                ))
            }
            PhysicsJointKind::Slider => {
                PhysicsJointConfiguration::Slider(SliderJointConfiguration::new(
                    axis_a,
                    axis_b,
                    min_limit,
                    max_limit,
                    PhysicsJointMotor::default(),
                    PhysicsJointSpring::default(),
                ))
            }
            PhysicsJointKind::Cone => PhysicsJointConfiguration::Cone(ConeJointConfiguration::new(
                axis_a,
                axis_b,
                std::f32::consts::FRAC_PI_4,
                min_limit,
                max_limit,
                PhysicsJointSpring::default(),
            )),
            PhysicsJointKind::SixDof => {
                PhysicsJointConfiguration::SixDof(SixDofJointConfiguration::new(
                    axis_a,
                    axis_b,
                    Float3::ZERO,
                    Float3::ZERO,
                    Float3::ZERO,
                    Float3::ZERO,
                    PhysicsJointMotor::default(),
                    PhysicsJointMotor::default(),
                    PhysicsJointSpring::default(),
                ))
            }
        };
        PhysicsJoint::new(
            configuration,
            entity_a,
            entity_b,
            pivot_a,
            pivot_b,
            is_enabled,
            break_force,
            break_torque,
        )
    }

    pub fn constraint_type(&self) -> PhysicsJointKind {
        self.configuration.kind()
    }

    /// The joint's primary axis pair. Point and distance joints report +Y +Y.
    fn axes(&self) -> (Float3, Float3) {
        let up = Float3::new(0.0, 1.0, 0.0);
        match &self.configuration {
            PhysicsJointConfiguration::Point | PhysicsJointConfiguration::Distance(_) => (up, up),
            PhysicsJointConfiguration::Fixed { axis_a, axis_b } => (*axis_a, *axis_b),
            PhysicsJointConfiguration::Hinge(value) => (value.axis_a, value.axis_b),
            PhysicsJointConfiguration::Slider(value) => (value.axis_a, value.axis_b),
            PhysicsJointConfiguration::Cone(value) => (value.twist_axis_a, value.twist_axis_b),
            PhysicsJointConfiguration::SixDof(value) => (value.axis_a, value.axis_b),
        }
    }

    /// Scalar limits, or `(0, 0)` for kinds that carry none.
    fn scalar_limits(&self) -> (f32, f32) {
        match &self.configuration {
            PhysicsJointConfiguration::Distance(value) => {
                (value.minimum_distance, value.maximum_distance)
            }
            PhysicsJointConfiguration::Hinge(value) => (value.minimum_angle, value.maximum_angle),
            PhysicsJointConfiguration::Slider(value) => {
                (value.minimum_distance, value.maximum_distance)
            }
            PhysicsJointConfiguration::Cone(value) => {
                (value.minimum_twist_angle, value.maximum_twist_angle)
            }
            _ => (0.0, 0.0),
        }
    }

    pub fn axis_a(&self) -> Float3 {
        self.axes().0
    }

    pub fn axis_b(&self) -> Float3 {
        self.axes().1
    }

    pub fn min_limit(&self) -> f32 {
        self.scalar_limits().0
    }

    pub fn max_limit(&self) -> f32 {
        self.scalar_limits().1
    }

    /// Writing an axis is a no-op for point and distance joints.
    pub fn set_axes(&mut self, axis_a: Float3, axis_b: Float3) {
        match &mut self.configuration {
            PhysicsJointConfiguration::Point | PhysicsJointConfiguration::Distance(_) => {}
            PhysicsJointConfiguration::Fixed {
                axis_a: current_a,
                axis_b: current_b,
            } => {
                *current_a = axis_a;
                *current_b = axis_b;
            }
            PhysicsJointConfiguration::Hinge(value) => {
                value.axis_a = axis_a;
                value.axis_b = axis_b;
            }
            PhysicsJointConfiguration::Slider(value) => {
                value.axis_a = axis_a;
                value.axis_b = axis_b;
            }
            PhysicsJointConfiguration::Cone(value) => {
                value.twist_axis_a = axis_a;
                value.twist_axis_b = axis_b;
            }
            PhysicsJointConfiguration::SixDof(value) => {
                value.axis_a = axis_a;
                value.axis_b = axis_b;
            }
        }
    }

    pub fn set_axis_a(&mut self, axis: Float3) {
        let current_b = self.axis_b();
        self.set_axes(axis, current_b);
    }

    pub fn set_axis_b(&mut self, axis: Float3) {
        let current_a = self.axis_a();
        self.set_axes(current_a, axis);
    }

    /// Writing scalar limits is a no-op for kinds that carry none.
    pub fn set_scalar_limits(&mut self, minimum: f32, maximum: f32) {
        match &mut self.configuration {
            PhysicsJointConfiguration::Distance(value) => {
                value.minimum_distance = minimum;
                value.maximum_distance = maximum;
            }
            PhysicsJointConfiguration::Hinge(value) => {
                value.minimum_angle = minimum;
                value.maximum_angle = maximum;
            }
            PhysicsJointConfiguration::Slider(value) => {
                value.minimum_distance = minimum;
                value.maximum_distance = maximum;
            }
            PhysicsJointConfiguration::Cone(value) => {
                value.minimum_twist_angle = minimum;
                value.maximum_twist_angle = maximum;
            }
            _ => {}
        }
    }

    pub fn set_min_limit(&mut self, value: f32) {
        let maximum = self.max_limit();
        self.set_scalar_limits(value, maximum);
    }

    pub fn set_max_limit(&mut self, value: f32) {
        let minimum = self.min_limit();
        self.set_scalar_limits(minimum, value);
    }
}

impl RuntimeComponent for PhysicsJoint {}

/// Swift `public typealias Constraint = PhysicsJoint`.
pub type Constraint = PhysicsJoint;

/// Swift `public typealias ConstraintType = PhysicsJointKind`.
pub type ConstraintType = PhysicsJointKind;

#[cfg(test)]
mod tests {
    use super::*;

    fn joint(configuration: PhysicsJointConfiguration) -> PhysicsJoint {
        PhysicsJoint::new(
            configuration,
            EntityID::new(0, 0),
            EntityID::new(1, 0),
            Float3::ZERO,
            Float3::ZERO,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        )
    }

    #[test]
    fn break_limits_clamp_to_zero() {
        let value = joint(PhysicsJointConfiguration::Point);
        assert_eq!(value.break_force, PhysicsJoint::DEFAULT_BREAK_LIMIT);
        let clamped = PhysicsJoint::new(
            PhysicsJointConfiguration::Point,
            EntityID::new(0, 0),
            EntityID::new(1, 0),
            Float3::ZERO,
            Float3::ZERO,
            true,
            -5.0,
            -9.0,
        );
        assert_eq!(clamped.break_force, 0.0);
        assert_eq!(clamped.break_torque, 0.0);
    }

    #[test]
    fn point_joint_reports_up_axes_and_zero_limits() {
        let value = joint(PhysicsJointConfiguration::Point);
        assert_eq!(value.axis_a(), Float3::new(0.0, 1.0, 0.0));
        assert_eq!(value.min_limit(), 0.0);
        assert_eq!(value.constraint_type(), PhysicsJointKind::PointToPoint);
    }

    #[test]
    fn setting_axis_preserves_other_hinge_fields() {
        let hinge = HingeJointConfiguration::new(
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            -1.0,
            1.0,
            PhysicsJointMotor::default(),
            PhysicsJointSpring::default(),
        );
        let mut value = joint(PhysicsJointConfiguration::Hinge(hinge));
        value.set_axis_a(Float3::new(1.0, 0.0, 0.0));
        assert_eq!(value.min_limit(), -1.0);
        assert_eq!(value.max_limit(), 1.0);
        assert_eq!(value.axis_b(), Float3::new(0.0, 1.0, 0.0));
        match &value.configuration {
            PhysicsJointConfiguration::Hinge(h) => {
                assert_eq!(h.axis_a, Float3::new(1.0, 0.0, 0.0));
            }
            _ => panic!("expected hinge"),
        }
    }

    #[test]
    fn setting_limits_on_point_joint_is_a_noop() {
        let mut value = joint(PhysicsJointConfiguration::Point);
        value.set_scalar_limits(1.0, 2.0);
        assert_eq!(value.min_limit(), 0.0);
        assert_eq!(value.max_limit(), 0.0);
    }

    #[test]
    fn from_kind_distance_orders_limits() {
        let value = PhysicsJoint::from_kind(
            PhysicsJointKind::Distance,
            EntityID::new(0, 0),
            EntityID::new(1, 0),
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            5.0,
            2.0,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        );
        assert_eq!(value.min_limit(), 5.0);
        assert_eq!(value.max_limit(), 5.0);
    }

    #[test]
    fn from_kind_fixed_keeps_axes() {
        let value = PhysicsJoint::from_kind(
            PhysicsJointKind::Fixed,
            EntityID::new(0, 0),
            EntityID::new(1, 0),
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            0.0,
            0.0,
            false,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        );
        assert_eq!(value.axis_a(), Float3::new(1.0, 0.0, 0.0));
        assert_eq!(value.axis_b(), Float3::new(0.0, 0.0, 1.0));
        assert!(!value.is_enabled);
    }
}
