extension ComponentInspection {
    static var rigidBody: Self {
        Self { inspection in
            inspection.sectionID = "rigid-body"
            inspection.inferredFieldsAreAdvanced = true
            inspection.fields = [
                field("motionType", id: "motion", label: "Motion", kind: .options,
                      choices: RigidBodyMotionType.allCases.map(\.rawValue)),
                field("mass", label: "Mass", min: 0, step: 0.5),
                field("massMode", id: "mass-mode", label: "Mass Mode"),
                field("maxLinearVelocity", id: "max-linear-velocity", label: "Max Linear Velocity"),
                field("maxAngularVelocity", id: "max-angular-velocity", label: "Max Angular Velocity"),
                field("axisLocks", id: "axis-locks", label: "Axis Locks"),
                field("linearVelocity", id: "linear-velocity", label: "Linear Velocity"),
                field("angularVelocity", id: "angular-velocity", label: "Angular Velocity"),
                field("gravityScale", id: "gravity-scale", label: "Gravity", step: 0.1),
                field("linearDamping", id: "linear-damping", label: "Linear Damping", min: 0, step: 0.01),
                field("angularDamping", id: "angular-damping", label: "Angular Damping", min: 0, step: 0.01),
                field("continuousCollisionDetection", id: "continuous-collision-detection", label: "Continuous Collision"),
                field("allowSleep", id: "allow-sleep", label: "Allow Sleep"),
                field("isSleeping", id: "sleeping", label: "Sleeping"),
            ]
            for index in [2, 3, 4, 5, 13] { inspection.fields[index].isReadOnly = true }
            for key in ["accumulatedForce", "accumulatedTorque", "accumulatedLinearImpulse",
                        "accumulatedAngularImpulse", "motionQuality", "kinematicTarget"] {
                inspection.fields.append(ComponentFieldDescriptor([key]) {
                    $0.isReadOnly = true
                    $0.isAdvanced = true
                })
            }
        }
    }
}
