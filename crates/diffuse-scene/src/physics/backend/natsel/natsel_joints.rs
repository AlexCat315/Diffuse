//! Joint creation and positional error reporting for the Natsel backend.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Backend/Natsel/NatselJoints.swift`.
//!
//! Two conversions here are easy to get subtly wrong:

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_cross, simd_dot, simd_length};

use natsel::types::ids::JointID;

use crate::physics::backend::physics_descriptors::PhysicsConstraintDescriptor;
use crate::physics::joints::physics_joint::PhysicsJoint;
use crate::physics::joints::physics_joint_configuration::{
    PhysicsJointConfiguration, PhysicsJointMotorMode,
};
use crate::physics::physics_types::{PhysicsBackendError, PhysicsBackendErrorCode};

use super::natsel_physics_backend::NatselPhysicsBackend;

impl NatselPhysicsBackend {
    /// `jointPositionError(_:)` — distance joints report only the travel beyond their
    /// limits; every other kind reports the raw pivot separation. Returning the raw
    /// distance for a distance joint would count its resting length as error.
    pub(crate) fn joint_position_error(&self, joint: &PhysicsJoint) -> f32 {
        let (Some(a), Some(b)) = (
            self.bodies.get(&joint.entity_a).map(|record| record.id),
            self.bodies.get(&joint.entity_b).map(|record| record.id),
        ) else {
            return 0.0;
        };
        let point_a = self
            .world
            .body_world_point(a, NatselPhysicsBackend::nv(joint.pivot_a));
        let point_b = self
            .world
            .body_world_point(b, NatselPhysicsBackend::nv(joint.pivot_b));
        let distance = simd_length(NatselPhysicsBackend::sv(natsel::math::functions::sub_pos(
            point_b, point_a,
        )));
        if let PhysicsJointConfiguration::Distance(limits) = &joint.configuration {
            return (limits.minimum_distance - distance)
                .max(distance - limits.maximum_distance)
                .max(0.0);
        }
        distance
    }

    /// `axisRotation(_:from:)` — the shortest arc taking `from` onto `axis`. The
    /// antiparallel case is singular, so it picks any perpendicular.
    fn axis_rotation(axis: Float3, from: Float3) -> natsel::math::types::Quat {
        let length = simd_length(axis);
        let target = if length > 0.000_001 {
            axis / length
        } else {
            from
        };
        let dot = simd_dot(from, target);
        if dot < -0.99999 {
            let reference = if from.x.abs() < 0.9 {
                let value = simd_cross(from, Float3::new(1.0, 0.0, 0.0));
                value / simd_length(value)
            } else {
                let value = simd_cross(from, Float3::new(0.0, 1.0, 0.0));
                value / simd_length(value)
            };
            return NatselPhysicsBackend::nq(Float4::new(
                reference.x,
                reference.y,
                reference.z,
                0.0,
            ));
        }
        let cross = simd_cross(from, target);
        NatselPhysicsBackend::nq(Float4::new(cross.x, cross.y, cross.z, 1.0 + dot))
    }

    /// `upsertJoint(_:)` — recreate only when the descriptor changed or the handle
    /// died. Natsel joints are immutable, so a config change is destroy-and-create.
    pub(crate) fn upsert_joint(
        &mut self,
        descriptor: &PhysicsConstraintDescriptor,
    ) -> Result<(), PhysicsBackendError> {
        if self.joint_descriptors.get(&descriptor.entity) == Some(descriptor)
            && let Some(id) = self.joints.get(&descriptor.entity)
            && self.world.joint_is_valid(*id)
        {
            return Ok(());
        }
        self.remove_joint(descriptor.entity);

        let joint = descriptor.constraint.clone();
        if !joint.is_enabled {
            return Ok(());
        }
        let (Some(a), Some(b)) = (
            self.bodies.get(&joint.entity_a).map(|record| record.id),
            self.bodies.get(&joint.entity_b).map(|record| record.id),
        ) else {
            return Ok(());
        };
        if a == b {
            return Err(NatselPhysicsBackend::failure(
                PhysicsBackendErrorCode::InvalidArgument,
                "A joint needs two distinct bodies",
            ));
        }

        // Local frames are body-local, so the pivots are `Vec3`, not world `Pos`.
        let mut local_frame_a = natsel::math::types::Transform::IDENTITY;
        local_frame_a.p = NatselPhysicsBackend::nv(joint.pivot_a);
        local_frame_a.q = Self::axis_rotation(joint.axis_a(), Float3::new(0.0, 0.0, 1.0));
        let mut local_frame_b = natsel::math::types::Transform::IDENTITY;
        local_frame_b.p = NatselPhysicsBackend::nv(joint.pivot_b);
        local_frame_b.q = Self::axis_rotation(joint.axis_b(), Float3::new(0.0, 0.0, 1.0));
        let base = natsel::types::joint_defs::JointDef {
            body_id_a: a,
            body_id_b: b,
            local_frame_a,
            local_frame_b,
            ..natsel::types::joint_defs::JointDef::default()
        };

        let id: JointID = match &joint.configuration {
            PhysicsJointConfiguration::Point => {
                let def = natsel::types::joint_defs::SphericalJointDef {
                    base: base.clone(),
                    ..natsel::types::joint_defs::SphericalJointDef::default()
                };
                self.world.create_spherical_joint(&def)
            }
            PhysicsJointConfiguration::Fixed { .. } => {
                let def = natsel::types::joint_defs::WeldJointDef {
                    base: base.clone(),
                    ..natsel::types::joint_defs::WeldJointDef::default()
                };
                self.world.create_weld_joint(&def)
            }
            PhysicsJointConfiguration::Distance(value) => {
                let mut def = natsel::types::joint_defs::DistanceJointDef::default();
                def.base = base;
                def.enable_limit = true;
                def.min_length = value.minimum_distance.max(0.0);
                def.max_length = def.min_length.max(value.maximum_distance);
                let point_a = self
                    .world
                    .body_world_point(a, NatselPhysicsBackend::nv(joint.pivot_a));
                let point_b = self
                    .world
                    .body_world_point(b, NatselPhysicsBackend::nv(joint.pivot_b));
                let current = simd_length(NatselPhysicsBackend::sv(
                    natsel::math::functions::sub_pos(point_b, point_a),
                ));
                def.length = current.min(def.max_length).max(def.min_length);
                def.enable_spring = value.spring.frequency > 0.0;
                def.hertz = value.spring.frequency;
                def.damping_ratio = value.spring.damping;
                self.world.create_distance_joint(&def)
            }
            PhysicsJointConfiguration::Hinge(value) => {
                let mut def = natsel::types::joint_defs::RevoluteJointDef::default();
                def.base = base;
                def.enable_limit = true;
                // Natsel's limit is `±0.99π`; the authored angle is clamped inside it.
                def.lower_angle = value.minimum_angle.max(-0.99 * std::f32::consts::PI);
                def.upper_angle = value
                    .maximum_angle
                    .min(0.99 * std::f32::consts::PI)
                    .max(def.lower_angle);
                def.enable_spring = value.spring.frequency > 0.0
                    || value.motor.mode == PhysicsJointMotorMode::Position;
                def.hertz = if value.spring.frequency > 0.0 {
                    value.spring.frequency
                } else {
                    5.0
                };
                def.damping_ratio = value.spring.damping;
                def.target_angle = value.motor.target_position;
                def.enable_motor = value.motor.mode == PhysicsJointMotorMode::Velocity;
                def.motor_speed = value.motor.target_velocity;
                def.max_motor_torque = value.motor.max_force;
                self.world.create_revolute_joint(&def)
            }
            PhysicsJointConfiguration::Slider(value) => {
                // A slider's frame is built on +X, unlike the +Z used above.
                let slider_base = natsel::types::joint_defs::JointDef {
                    local_frame_a: natsel::math::types::Transform::new(
                        local_frame_a.p,
                        Self::axis_rotation(value.axis_a, Float3::new(1.0, 0.0, 0.0)),
                    ),
                    local_frame_b: natsel::math::types::Transform::new(
                        local_frame_b.p,
                        Self::axis_rotation(value.axis_b, Float3::new(1.0, 0.0, 0.0)),
                    ),
                    ..base.clone()
                };
                let mut def = natsel::types::joint_defs::PrismaticJointDef {
                    base: slider_base,
                    enable_limit: true,
                    ..natsel::types::joint_defs::PrismaticJointDef::default()
                };
                def.lower_translation = value.minimum_distance;
                def.upper_translation = value.maximum_distance.max(value.minimum_distance);
                def.enable_spring = value.spring.frequency > 0.0
                    || value.motor.mode == PhysicsJointMotorMode::Position;
                def.hertz = if value.spring.frequency > 0.0 {
                    value.spring.frequency
                } else {
                    5.0
                };
                def.damping_ratio = value.spring.damping;
                def.target_translation = value.motor.target_position;
                def.enable_motor = value.motor.mode == PhysicsJointMotorMode::Velocity;
                def.motor_speed = value.motor.target_velocity;
                def.max_motor_force = value.motor.max_force;
                self.world.create_prismatic_joint(&def)
            }
            PhysicsJointConfiguration::Cone(value) => {
                let mut def = natsel::types::joint_defs::SphericalJointDef {
                    base: base.clone(),
                    enable_cone_limit: true,
                    ..natsel::types::joint_defs::SphericalJointDef::default()
                };
                def.cone_angle = value.half_cone_angle;
                def.enable_twist_limit = true;
                def.lower_twist_angle = value.minimum_twist_angle;
                def.upper_twist_angle = value.maximum_twist_angle;
                def.enable_spring = value.spring.frequency > 0.0;
                def.hertz = value.spring.frequency;
                def.damping_ratio = value.spring.damping;
                self.world.create_spherical_joint(&def)
            }
            PhysicsJointConfiguration::SixDof(value) => {
                // Six-DOF frames are built on +X as well.
                let six_dof_base = natsel::types::joint_defs::JointDef {
                    local_frame_a: natsel::math::types::Transform::new(
                        local_frame_a.p,
                        Self::axis_rotation(value.axis_a, Float3::new(1.0, 0.0, 0.0)),
                    ),
                    local_frame_b: natsel::math::types::Transform::new(
                        local_frame_b.p,
                        Self::axis_rotation(value.axis_b, Float3::new(1.0, 0.0, 0.0)),
                    ),
                    ..base.clone()
                };
                let mut def = natsel::simulation::six_dof_joint::SixDOFJointDef {
                    base: six_dof_base,
                    ..natsel::simulation::six_dof_joint::SixDOFJointDef::default()
                };
                let linear_minimum = [
                    value.linear_minimum.x,
                    value.linear_minimum.y,
                    value.linear_minimum.z,
                ];
                let linear_maximum = [
                    value.linear_maximum.x,
                    value.linear_maximum.y,
                    value.linear_maximum.z,
                ];
                let angular_minimum = [
                    value.angular_minimum.x,
                    value.angular_minimum.y,
                    value.angular_minimum.z,
                ];
                let angular_maximum = [
                    value.angular_maximum.x,
                    value.angular_maximum.y,
                    value.angular_maximum.z,
                ];
                for axis in 0..6 {
                    let (lower, upper, motor) = if axis < 3 {
                        (
                            linear_minimum[axis],
                            linear_maximum[axis],
                            &value.linear_motor,
                        )
                    } else {
                        (
                            angular_minimum[axis - 3],
                            angular_maximum[axis - 3],
                            &value.angular_motor,
                        )
                    };
                    // A reversed range means free, an equal range means locked; that
                    // ordering is how the authored intent is encoded.
                    def.axes[axis].motion = if lower > upper {
                        natsel::simulation::six_dof_joint::SixDOFMotion::Free
                    } else if lower == upper {
                        natsel::simulation::six_dof_joint::SixDOFMotion::Locked
                    } else {
                        natsel::simulation::six_dof_joint::SixDOFMotion::Limited
                    };
                    def.axes[axis].lower_limit = lower;
                    def.axes[axis].upper_limit = upper;
                    def.axes[axis].limit_hertz = value.spring.frequency;
                    def.axes[axis].limit_damping_ratio = value.spring.damping;
                    def.axes[axis].motor_mode = match motor.mode {
                        PhysicsJointMotorMode::Disabled => {
                            natsel::simulation::six_dof_joint::SixDOFMotorMode::Off
                        }
                        PhysicsJointMotorMode::Velocity => {
                            natsel::simulation::six_dof_joint::SixDOFMotorMode::Velocity
                        }
                        PhysicsJointMotorMode::Position => {
                            natsel::simulation::six_dof_joint::SixDOFMotorMode::Position
                        }
                    };
                    def.axes[axis].motor_target = if motor.mode == PhysicsJointMotorMode::Velocity {
                        motor.target_velocity
                    } else {
                        motor.target_position
                    };
                    def.axes[axis].max_motor_force = motor.max_force;
                }
                self.world.create_six_dof_joint(def)
            }
        };

        if !self.world.joint_is_valid(id) {
            return Err(NatselPhysicsBackend::failure(
                PhysicsBackendErrorCode::InvalidArgument,
                "Could not create Natsel joint",
            ));
        }
        self.joints.insert(descriptor.entity, id);
        self.joint_descriptors
            .insert(descriptor.entity, descriptor.clone());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entity_id::EntityID;

    #[test]
    fn axis_rotation_maps_axis_onto_itself() {
        let rotation = NatselPhysicsBackend::axis_rotation(
            Float3::new(0.0, 0.0, 1.0),
            Float3::new(0.0, 0.0, 1.0),
        );
        // Same direction: 180-degree-free identity-ish arc.
        let rotated = natsel::math::functions::rotate_vector(
            rotation,
            NatselPhysicsBackend::nv(Float3::new(0.0, 0.0, 1.0)),
        );
        assert!((rotated.z - 1.0).abs() < 1e-5);
    }

    #[test]
    fn axis_rotation_handles_the_antiparallel_singularity() {
        // from = +Y, target = -Y is the singular case; any perpendicular is correct,
        // but the result must stay a unit quaternion rather than NaN.
        let rotation = NatselPhysicsBackend::axis_rotation(
            Float3::new(0.0, -1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
        );
        let norm = (rotation.v.x * rotation.v.x
            + rotation.v.y * rotation.v.y
            + rotation.v.z * rotation.v.z
            + rotation.s * rotation.s)
            .sqrt();
        assert!(norm > 0.9 && norm < 1.1, "norm was {norm}");
    }

    #[test]
    fn axis_rotation_falls_back_to_from_when_axis_is_zero() {
        let rotation =
            NatselPhysicsBackend::axis_rotation(Float3::ZERO, Float3::new(0.0, 0.0, 1.0));
        // from == target, so the arc is the identity.
        assert!(rotation.s.is_finite());
    }

    #[test]
    fn joint_position_error_is_zero_for_a_missing_body() {
        let backend = NatselPhysicsBackend::new();
        let joint = PhysicsJoint::from_kind(
            crate::physics::joints::physics_joint_configuration::PhysicsJointKind::PointToPoint,
            EntityID::new(1, 0),
            EntityID::new(2, 0),
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            0.0,
            0.0,
            true,
            1.0,
            1.0,
        );
        assert_eq!(backend.joint_position_error(&joint), 0.0);
    }
}
