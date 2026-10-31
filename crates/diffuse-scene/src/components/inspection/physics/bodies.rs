//! `Inspection/Physics/Bodies.swift` — the rigid-body form.
//!
//! Simulation-owned values (mass mode, velocity limits, axis locks, sleeping) are
//! read-only, and the accumulated solver state is exposed as advanced, read-only
//! fields that the codec only writes during a snapshot encode.

use crate::components::inspection::builtin_inspection::{field, ComponentFieldSpec};
use crate::components::inspection::inspection::{
    ComponentFieldDescriptor, ComponentFieldKind, ComponentInspection,
};
use crate::physics::rigid_body::RigidBodyMotionType;

impl ComponentInspection {
    /// Swift `rigidBody`.
    pub fn rigid_body() -> Self {
        let mut inspection = ComponentInspection {
            section_id: Some("rigid-body".to_string()),
            inferred_fields_are_advanced: true,
            fields: vec![
                field(
                    ComponentFieldSpec::new("motionType", "Motion")
                        .id("motion")
                        .kind(ComponentFieldKind::Options)
                        .choices(
                            RigidBodyMotionType::ALL
                                .iter()
                                .map(|value| value.raw_value().to_string()),
                        ),
                ),
                field(
                    ComponentFieldSpec::new("mass", "Mass")
                        .minimum(0.0)
                        .step(0.5),
                ),
                field(ComponentFieldSpec::new("massMode", "Mass Mode").id("mass-mode")),
                field(
                    ComponentFieldSpec::new("maxLinearVelocity", "Max Linear Velocity")
                        .id("max-linear-velocity"),
                ),
                field(
                    ComponentFieldSpec::new("maxAngularVelocity", "Max Angular Velocity")
                        .id("max-angular-velocity"),
                ),
                field(ComponentFieldSpec::new("axisLocks", "Axis Locks").id("axis-locks")),
                field(
                    ComponentFieldSpec::new("linearVelocity", "Linear Velocity")
                        .id("linear-velocity"),
                ),
                field(
                    ComponentFieldSpec::new("angularVelocity", "Angular Velocity")
                        .id("angular-velocity"),
                ),
                field(
                    ComponentFieldSpec::new("gravityScale", "Gravity")
                        .id("gravity-scale")
                        .step(0.1),
                ),
                field(
                    ComponentFieldSpec::new("linearDamping", "Linear Damping")
                        .id("linear-damping")
                        .minimum(0.0)
                        .step(0.01),
                ),
                field(
                    ComponentFieldSpec::new("angularDamping", "Angular Damping")
                        .id("angular-damping")
                        .minimum(0.0)
                        .step(0.01),
                ),
                field(
                    ComponentFieldSpec::new(
                        "continuousCollisionDetection",
                        "Continuous Collision",
                    )
                    .id("continuous-collision-detection"),
                ),
                field(
                    ComponentFieldSpec::new("allowSleep", "Allow Sleep").id("allow-sleep"),
                ),
                field(ComponentFieldSpec::new("isSleeping", "Sleeping").id("sleeping")),
            ],
            ..ComponentInspection::default()
        };
        for index in [2, 3, 4, 5, 13] {
            inspection.fields[index].is_read_only = true;
        }
        for key in [
            "accumulatedForce",
            "accumulatedTorque",
            "accumulatedLinearImpulse",
            "accumulatedAngularImpulse",
            "motionQuality",
            "kinematicTarget",
        ] {
            let mut descriptor = ComponentFieldDescriptor::new(vec![key.to_string()]);
            descriptor.is_read_only = true;
            descriptor.is_advanced = true;
            inspection.fields.push(descriptor);
        }
        inspection
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simulation_owned_fields_are_read_only() {
        let inspection = ComponentInspection::rigid_body();
        assert_eq!(inspection.section_id.as_deref(), Some("rigid-body"));
        assert!(inspection.inferred_fields_are_advanced);
        for index in [2, 3, 4, 5, 13] {
            assert!(inspection.fields[index].is_read_only, "index {index}");
        }
        assert!(!inspection.fields[1].is_read_only);
        assert_eq!(inspection.fields[0].choices.len(), 3);
        assert_eq!(inspection.fields.len(), 20);
    }

    #[test]
    fn solver_state_is_appended_as_advanced_read_only() {
        let inspection = ComponentInspection::rigid_body();
        let accumulated = &inspection.fields[14];
        assert_eq!(accumulated.path, vec!["accumulatedForce".to_string()]);
        assert!(accumulated.is_read_only);
        assert!(accumulated.is_advanced);
        assert_eq!(accumulated.id, "accumulatedForce");
        assert_eq!(accumulated.label, "Accumulated Force");
    }
}
