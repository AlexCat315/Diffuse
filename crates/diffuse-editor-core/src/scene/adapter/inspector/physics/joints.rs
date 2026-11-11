//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Physics/Joints.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_math::simd::simd_compat::{Float3, simd_max, simd_min};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::collider::Collider;
use diffuse_scene::physics::joints::physics_joint::{Constraint, PhysicsJoint};
use diffuse_scene::physics::joints::physics_joint_configuration::{
    ConeJointConfiguration, DistanceJointConfiguration, HingeJointConfiguration,
    PhysicsJointConfiguration, PhysicsJointKind, PhysicsJointMotor, PhysicsJointSpring,
    SixDofJointConfiguration, SliderJointConfiguration,
};

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorEntityOption, EditorInspectorField, EditorInspectorFieldValue,
    EditorInspectorSection,
};

#[derive(Clone, Copy, PartialEq)]
enum JointVectorField {
    PivotA,
    PivotB,
    AxisA,
    AxisB,
    LinearMinimum,
    LinearMaximum,
    AngularMinimum,
    AngularMaximum,
}

#[derive(Clone, Copy, PartialEq)]
enum JointScalarField {
    MinimumLimit,
    MaximumLimit,
    HalfConeAngle,
    SpringFrequency,
    SpringDamping,
    BreakForce,
    BreakTorque,
}

#[derive(Clone, Copy)]
enum MotorSlot {
    Primary,
    Angular,
}

#[derive(Clone, Copy)]
enum MotorScalarField {
    TargetPosition,
    TargetVelocity,
    MaximumForce,
}

#[derive(Clone, Copy, PartialEq)]
enum JointEndpoint {
    A,
    B,
}

#[derive(Clone, Copy)]
enum Axis {
    X,
    Y,
    Z,
}

impl EditorSceneAdapter {
    pub(crate) fn constraint_section(&self, entity: EntityID) -> Option<EditorInspectorSection> {
        let joint = self.scene().component::<PhysicsJoint>(entity)?;
        let endpoint_options = self.physics_joint_endpoint_options(entity);

        let mut fields: Vec<EditorInspectorField> = vec![
            EditorInspectorField::new(
                "joint-type",
                localized("Type"),
                EditorInspectorFieldValue::options(&self.physics_joint_kind_binding(entity)),
            ),
            EditorInspectorField::new(
                "joint-entity-a",
                localized("Entity A"),
                EditorInspectorFieldValue::EntityReference {
                    binding: self.physics_joint_endpoint_binding(entity, JointEndpoint::A),
                    options: endpoint_options.clone(),
                },
            ),
            EditorInspectorField::new(
                "joint-entity-b",
                localized("Entity B"),
                EditorInspectorFieldValue::EntityReference {
                    binding: self.physics_joint_endpoint_binding(entity, JointEndpoint::B),
                    options: endpoint_options,
                },
            ),
            self.joint_vector_field(
                "joint-pivot-a",
                "Anchor A",
                entity,
                JointVectorField::PivotA,
            ),
            self.joint_vector_field(
                "joint-pivot-b",
                "Anchor B",
                entity,
                JointVectorField::PivotB,
            ),
        ];

        match &joint.configuration {
            PhysicsJointConfiguration::Point => {}
            PhysicsJointConfiguration::Fixed { .. } => {
                fields.push(self.joint_vector_field(
                    "joint-axis-a",
                    "Axis A",
                    entity,
                    JointVectorField::AxisA,
                ));
                fields.push(self.joint_vector_field(
                    "joint-axis-b",
                    "Axis B",
                    entity,
                    JointVectorField::AxisB,
                ));
            }
            PhysicsJointConfiguration::Distance(_) => {
                fields.push(self.joint_scalar_field(
                    "joint-minimum-distance",
                    "Minimum Distance",
                    entity,
                    JointScalarField::MinimumLimit,
                    Some(0.0),
                ));
                fields.push(self.joint_scalar_field(
                    "joint-maximum-distance",
                    "Maximum Distance",
                    entity,
                    JointScalarField::MaximumLimit,
                    Some(0.0),
                ));
                fields.extend(self.joint_spring_fields(entity));
            }
            PhysicsJointConfiguration::Hinge(_) => {
                fields.push(self.joint_vector_field(
                    "joint-axis-a",
                    "Axis A",
                    entity,
                    JointVectorField::AxisA,
                ));
                fields.push(self.joint_vector_field(
                    "joint-axis-b",
                    "Axis B",
                    entity,
                    JointVectorField::AxisB,
                ));
                fields.push(self.joint_scalar_field(
                    "joint-minimum-angle",
                    "Minimum Angle (rad)",
                    entity,
                    JointScalarField::MinimumLimit,
                    None,
                ));
                fields.push(self.joint_scalar_field(
                    "joint-maximum-angle",
                    "Maximum Angle (rad)",
                    entity,
                    JointScalarField::MaximumLimit,
                    None,
                ));
                fields.extend(self.joint_motor_fields(
                    entity,
                    MotorSlot::Primary,
                    "motor",
                    "Motor",
                ));
                fields.extend(self.joint_spring_fields(entity));
            }
            PhysicsJointConfiguration::Slider(_) => {
                fields.push(self.joint_vector_field(
                    "joint-axis-a",
                    "Axis A",
                    entity,
                    JointVectorField::AxisA,
                ));
                fields.push(self.joint_vector_field(
                    "joint-axis-b",
                    "Axis B",
                    entity,
                    JointVectorField::AxisB,
                ));
                fields.push(self.joint_scalar_field(
                    "joint-minimum-distance",
                    "Minimum Distance",
                    entity,
                    JointScalarField::MinimumLimit,
                    None,
                ));
                fields.push(self.joint_scalar_field(
                    "joint-maximum-distance",
                    "Maximum Distance",
                    entity,
                    JointScalarField::MaximumLimit,
                    None,
                ));
                fields.extend(self.joint_motor_fields(
                    entity,
                    MotorSlot::Primary,
                    "motor",
                    "Motor",
                ));
                fields.extend(self.joint_spring_fields(entity));
            }
            PhysicsJointConfiguration::Cone(_) => {
                fields.push(self.joint_vector_field(
                    "joint-axis-a",
                    "Twist Axis A",
                    entity,
                    JointVectorField::AxisA,
                ));
                fields.push(self.joint_vector_field(
                    "joint-axis-b",
                    "Twist Axis B",
                    entity,
                    JointVectorField::AxisB,
                ));
                fields.push(self.joint_scalar_field(
                    "joint-half-cone-angle",
                    "Half Cone Angle (rad)",
                    entity,
                    JointScalarField::HalfConeAngle,
                    Some(0.0),
                ));
                fields.push(self.joint_scalar_field(
                    "joint-minimum-angle",
                    "Minimum Twist (rad)",
                    entity,
                    JointScalarField::MinimumLimit,
                    None,
                ));
                fields.push(self.joint_scalar_field(
                    "joint-maximum-angle",
                    "Maximum Twist (rad)",
                    entity,
                    JointScalarField::MaximumLimit,
                    None,
                ));
                fields.extend(self.joint_spring_fields(entity));
            }
            PhysicsJointConfiguration::SixDof(_) => {
                fields.push(self.joint_vector_field(
                    "joint-axis-a",
                    "Axis A",
                    entity,
                    JointVectorField::AxisA,
                ));
                fields.push(self.joint_vector_field(
                    "joint-axis-b",
                    "Axis B",
                    entity,
                    JointVectorField::AxisB,
                ));
                fields.push(self.joint_vector_field(
                    "joint-linear-minimum",
                    "Linear Minimum",
                    entity,
                    JointVectorField::LinearMinimum,
                ));
                fields.push(self.joint_vector_field(
                    "joint-linear-maximum",
                    "Linear Maximum",
                    entity,
                    JointVectorField::LinearMaximum,
                ));
                fields.push(self.joint_vector_field(
                    "joint-angular-minimum",
                    "Angular Minimum",
                    entity,
                    JointVectorField::AngularMinimum,
                ));
                fields.push(self.joint_vector_field(
                    "joint-angular-maximum",
                    "Angular Maximum",
                    entity,
                    JointVectorField::AngularMaximum,
                ));
                fields.extend(self.joint_motor_fields(
                    entity,
                    MotorSlot::Primary,
                    "linear",
                    "Linear",
                ));
                fields.extend(self.joint_motor_fields(
                    entity,
                    MotorSlot::Angular,
                    "angular",
                    "Angular",
                ));
                fields.extend(self.joint_spring_fields(entity));
            }
        }

        fields.push(self.joint_scalar_field(
            "joint-break-force",
            "Break Force",
            entity,
            JointScalarField::BreakForce,
            Some(0.0),
        ));
        fields.push(self.joint_scalar_field(
            "joint-break-torque",
            "Break Torque",
            entity,
            JointScalarField::BreakTorque,
            Some(0.0),
        ));
        fields.push(EditorInspectorField::new(
            "joint-enabled",
            localized("Enabled"),
            EditorInspectorFieldValue::Bool(self.constraint_enabled_binding(entity)),
        ));

        Some(EditorInspectorSection::new(
            "constraint",
            localized("Physics Joint"),
            fields,
        ))
    }

    fn physics_joint_endpoint_options(
        &self,
        joint_entity: EntityID,
    ) -> Vec<EditorInspectorEntityOption> {
        let scene = self.scene();
        let mut entities: Vec<EntityID> = scene
            .entities()
            .into_iter()
            .filter(|entity| *entity != joint_entity && scene.has_component::<Collider>(*entity))
            .collect();
        entities.sort_by_key(|entity| entity.raw_value());
        entities
            .into_iter()
            .map(|entity| {
                EditorInspectorEntityOption::new(entity.raw_value(), self.display_name(entity))
            })
            .collect()
    }

    fn physics_joint_endpoint_binding(
        &self,
        joint_entity: EntityID,
        endpoint: JointEndpoint,
    ) -> Binding<u64> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let Some(joint) = get_adapter.scene().component::<PhysicsJoint>(joint_entity)
                else {
                    return 0;
                };
                match endpoint {
                    JointEndpoint::A => joint.entity_a.raw_value(),
                    JointEndpoint::B => joint.entity_b.raw_value(),
                }
            },
            move |raw_id: u64| {
                let candidate = EntityID::from_raw_value(raw_id);
                let Some(current) = set_adapter.scene().component::<PhysicsJoint>(joint_entity)
                else {
                    return;
                };
                let (existing, other) = match endpoint {
                    JointEndpoint::A => (current.entity_a, current.entity_b),
                    JointEndpoint::B => (current.entity_b, current.entity_a),
                };
                let scene = set_adapter.scene();
                if !scene.contains(candidate)
                    || !scene.has_component::<Collider>(candidate)
                    || candidate == existing
                    || candidate == other
                {
                    return;
                }
                let _ = set_adapter.update_component_data::<PhysicsJoint>(joint_entity, |joint| {
                    match endpoint {
                        JointEndpoint::A => joint.entity_a = candidate,
                        JointEndpoint::B => joint.entity_b = candidate,
                    }
                });
            },
        )
    }

    fn joint_vector_field(
        &self,
        id: &str,
        label: &str,
        entity: EntityID,
        field: JointVectorField,
    ) -> EditorInspectorField {
        EditorInspectorField::new(
            id,
            localized(label),
            EditorInspectorFieldValue::Vector3 {
                x: self.physics_joint_vector_binding(entity, field, Axis::X),
                y: self.physics_joint_vector_binding(entity, field, Axis::Y),
                z: self.physics_joint_vector_binding(entity, field, Axis::Z),
            },
        )
    }

    fn joint_scalar_field(
        &self,
        id: &str,
        label: &str,
        entity: EntityID,
        field: JointScalarField,
        minimum: Option<f32>,
    ) -> EditorInspectorField {
        EditorInspectorField::new(
            id,
            localized(label),
            EditorInspectorFieldValue::ConstrainedNumber {
                binding: self.physics_joint_scalar_binding(entity, field, minimum),
                min: minimum,
                max: None,
                step: Some(0.05),
                shows_stepper: true,
            },
        )
    }

    fn joint_spring_fields(&self, entity: EntityID) -> Vec<EditorInspectorField> {
        vec![
            self.joint_scalar_field(
                "joint-spring-frequency",
                "Spring Frequency",
                entity,
                JointScalarField::SpringFrequency,
                Some(0.0),
            ),
            self.joint_scalar_field(
                "joint-spring-damping",
                "Spring Damping",
                entity,
                JointScalarField::SpringDamping,
                Some(0.0),
            ),
        ]
    }

    fn joint_motor_fields(
        &self,
        entity: EntityID,
        slot: MotorSlot,
        prefix: &str,
        label: &str,
    ) -> Vec<EditorInspectorField> {
        vec![
            EditorInspectorField::new(
                format!("joint-{prefix}-mode"),
                format!("{label} {}", localized("Mode")),
                EditorInspectorFieldValue::options(
                    &self.physics_joint_motor_mode_binding(entity, slot),
                ),
            ),
            EditorInspectorField::new(
                format!("joint-{prefix}-target-position"),
                format!("{label} {}", localized("Target Position")),
                EditorInspectorFieldValue::Number(self.physics_joint_motor_scalar_binding(
                    entity,
                    slot,
                    MotorScalarField::TargetPosition,
                )),
            ),
            EditorInspectorField::new(
                format!("joint-{prefix}-target-velocity"),
                format!("{label} {}", localized("Target Velocity")),
                EditorInspectorFieldValue::Number(self.physics_joint_motor_scalar_binding(
                    entity,
                    slot,
                    MotorScalarField::TargetVelocity,
                )),
            ),
            EditorInspectorField::new(
                format!("joint-{prefix}-maximum-force"),
                format!("{label} {}", localized("Maximum Force")),
                EditorInspectorFieldValue::ConstrainedNumber {
                    binding: self.physics_joint_motor_scalar_binding(
                        entity,
                        slot,
                        MotorScalarField::MaximumForce,
                    ),
                    min: Some(0.0),
                    max: None,
                    step: Some(1.0),
                    shows_stepper: true,
                },
            ),
        ]
    }

    fn physics_joint_kind_binding(&self, entity: EntityID) -> Binding<PhysicsJointKind> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<PhysicsJoint>(entity)
                    .map(|joint| joint.configuration.kind())
                    .unwrap_or(PhysicsJointKind::PointToPoint)
            },
            move |kind: PhysicsJointKind| {
                let _ = set_adapter.update_component_data::<PhysicsJoint>(entity, |joint| {
                    if joint.configuration.kind() == kind {
                        return;
                    }
                    joint.configuration = match kind {
                        PhysicsJointKind::PointToPoint => PhysicsJointConfiguration::Point,
                        PhysicsJointKind::Fixed => PhysicsJointConfiguration::Fixed {
                            axis_a: Float3::new(0.0, 1.0, 0.0),
                            axis_b: Float3::new(0.0, 1.0, 0.0),
                        },
                        PhysicsJointKind::Distance => {
                            PhysicsJointConfiguration::Distance(DistanceJointConfiguration::new(
                                0.0,
                                1.0,
                                PhysicsJointSpring::default(),
                            ))
                        }
                        PhysicsJointKind::Hinge => {
                            PhysicsJointConfiguration::Hinge(HingeJointConfiguration::default())
                        }
                        PhysicsJointKind::Slider => {
                            PhysicsJointConfiguration::Slider(SliderJointConfiguration::default())
                        }
                        PhysicsJointKind::Cone => {
                            PhysicsJointConfiguration::Cone(ConeJointConfiguration::default())
                        }
                        PhysicsJointKind::SixDof => {
                            PhysicsJointConfiguration::SixDof(SixDofJointConfiguration::default())
                        }
                    };
                });
            },
        )
    }

    fn physics_joint_vector_binding(
        &self,
        entity: EntityID,
        field: JointVectorField,
        axis: Axis,
    ) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<PhysicsJoint>(entity)
                    .map(|joint| axis_value(joint_vector(&joint, field), axis))
                    .unwrap_or(0.0)
            },
            move |next: f32| {
                let _ = set_adapter.update_component_data::<PhysicsJoint>(entity, |joint| {
                    let mut vector = joint_vector(joint, field);
                    if axis_value(vector, axis) == next {
                        return;
                    }
                    vector = set_axis_value(vector, axis, next);
                    set_joint_vector(joint, field, vector);
                });
            },
        )
    }

    fn physics_joint_scalar_binding(
        &self,
        entity: EntityID,
        field: JointScalarField,
        minimum: Option<f32>,
    ) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<PhysicsJoint>(entity)
                    .map(|joint| joint_scalar(&joint, field))
                    .unwrap_or(0.0)
            },
            move |next: f32| {
                let value = minimum.map(|minimum| minimum.max(next)).unwrap_or(next);
                let _ = set_adapter.update_component_data::<PhysicsJoint>(entity, |joint| {
                    if joint_scalar(joint, field) == value {
                        return;
                    }
                    set_joint_scalar(joint, field, value);
                });
            },
        )
    }

    fn physics_joint_motor_mode_binding(
        &self,
        entity: EntityID,
        slot: MotorSlot,
    ) -> Binding<diffuse_scene::physics::joints::physics_joint_configuration::PhysicsJointMotorMode>
    {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<PhysicsJoint>(entity)
                    .map(|joint| {
                        joint_motor(&joint, slot)
                            .map(|motor| motor.mode)
                            .unwrap_or(
                                diffuse_scene::physics::joints::physics_joint_configuration::PhysicsJointMotorMode::Disabled,
                            )
                    })
                    .unwrap_or(
                        diffuse_scene::physics::joints::physics_joint_configuration::PhysicsJointMotorMode::Disabled,
                    )
            },
            move |mode| {
                let _ = set_adapter.update_component_data::<PhysicsJoint>(entity, |joint| {
                    update_joint_motor(joint, slot, |motor| motor.mode = mode);
                });
            },
        )
    }

    fn physics_joint_motor_scalar_binding(
        &self,
        entity: EntityID,
        slot: MotorSlot,
        field: MotorScalarField,
    ) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<PhysicsJoint>(entity)
                    .map(|joint| {
                        joint_motor(&joint, slot)
                            .map(|motor| match field {
                                MotorScalarField::TargetPosition => motor.target_position,
                                MotorScalarField::TargetVelocity => motor.target_velocity,
                                MotorScalarField::MaximumForce => motor.max_force,
                            })
                            .unwrap_or(0.0)
                    })
                    .unwrap_or(0.0)
            },
            move |value: f32| {
                let _ = set_adapter.update_component_data::<PhysicsJoint>(entity, |joint| {
                    update_joint_motor(joint, slot, |motor| match field {
                        MotorScalarField::TargetPosition => motor.target_position = value,
                        MotorScalarField::TargetVelocity => motor.target_velocity = value,
                        MotorScalarField::MaximumForce => motor.max_force = value.max(0.0),
                    });
                });
            },
        )
    }

    fn constraint_enabled_binding(&self, entity: EntityID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Constraint>(entity)
                    .map(|joint| joint.is_enabled)
                    .unwrap_or(false)
            },
            move |next: bool| {
                let Some(joint) = set_adapter.scene().component::<Constraint>(entity) else {
                    return;
                };
                if joint.is_enabled == next {
                    return;
                }
                let _ = set_adapter.apply_scene_transaction(
                    "scene.set_constraint_enabled",
                    "Update constraint enabled flag",
                    vec![entity.raw_value()],
                    vec![SceneMutation::component_fields(
                        entity.raw_value(),
                        "constraint",
                        vec![("isEnabled".to_string(), Some(ComponentValue::Bool(next)))],
                    )],
                );
            },
        )
    }
}

fn axis_value(value: Float3, axis: Axis) -> f32 {
    match axis {
        Axis::X => value.x,
        Axis::Y => value.y,
        Axis::Z => value.z,
    }
}

fn set_axis_value(value: Float3, axis: Axis, component: f32) -> Float3 {
    match axis {
        Axis::X => Float3::new(component, value.y, value.z),
        Axis::Y => Float3::new(value.x, component, value.z),
        Axis::Z => Float3::new(value.x, value.y, component),
    }
}

fn joint_vector(joint: &PhysicsJoint, field: JointVectorField) -> Float3 {
    match field {
        JointVectorField::PivotA => joint.pivot_a,
        JointVectorField::PivotB => joint.pivot_b,
        JointVectorField::AxisA => joint.axis_a(),
        JointVectorField::AxisB => joint.axis_b(),
        JointVectorField::LinearMinimum => match &joint.configuration {
            PhysicsJointConfiguration::SixDof(value) => value.linear_minimum,
            _ => Float3::ZERO,
        },
        JointVectorField::LinearMaximum => match &joint.configuration {
            PhysicsJointConfiguration::SixDof(value) => value.linear_maximum,
            _ => Float3::ZERO,
        },
        JointVectorField::AngularMinimum => match &joint.configuration {
            PhysicsJointConfiguration::SixDof(value) => value.angular_minimum,
            _ => Float3::ZERO,
        },
        JointVectorField::AngularMaximum => match &joint.configuration {
            PhysicsJointConfiguration::SixDof(value) => value.angular_maximum,
            _ => Float3::ZERO,
        },
    }
}

fn set_joint_vector(joint: &mut PhysicsJoint, field: JointVectorField, vector: Float3) {
    match field {
        JointVectorField::PivotA => joint.pivot_a = vector,
        JointVectorField::PivotB => joint.pivot_b = vector,
        JointVectorField::AxisA => joint.set_axis_a(vector),
        JointVectorField::AxisB => joint.set_axis_b(vector),
        JointVectorField::LinearMinimum => {
            if let PhysicsJointConfiguration::SixDof(value) = &mut joint.configuration {
                value.linear_minimum = simd_min(vector, value.linear_maximum);
            }
        }
        JointVectorField::LinearMaximum => {
            if let PhysicsJointConfiguration::SixDof(value) = &mut joint.configuration {
                value.linear_maximum = simd_max(vector, value.linear_minimum);
            }
        }
        JointVectorField::AngularMinimum => {
            if let PhysicsJointConfiguration::SixDof(value) = &mut joint.configuration {
                value.angular_minimum = simd_min(vector, value.angular_maximum);
            }
        }
        JointVectorField::AngularMaximum => {
            if let PhysicsJointConfiguration::SixDof(value) = &mut joint.configuration {
                value.angular_maximum = simd_max(vector, value.angular_minimum);
            }
        }
    }
}

fn joint_scalar(joint: &PhysicsJoint, field: JointScalarField) -> f32 {
    match field {
        JointScalarField::MinimumLimit => joint.min_limit(),
        JointScalarField::MaximumLimit => joint.max_limit(),
        JointScalarField::HalfConeAngle => match &joint.configuration {
            PhysicsJointConfiguration::Cone(value) => value.half_cone_angle,
            _ => 0.0,
        },
        JointScalarField::SpringFrequency => joint_spring(&joint.configuration)
            .map(|spring| spring.frequency)
            .unwrap_or(0.0),
        JointScalarField::SpringDamping => joint_spring(&joint.configuration)
            .map(|spring| spring.damping)
            .unwrap_or(0.0),
        JointScalarField::BreakForce => joint.break_force,
        JointScalarField::BreakTorque => joint.break_torque,
    }
}

fn set_joint_scalar(joint: &mut PhysicsJoint, field: JointScalarField, scalar: f32) {
    match field {
        JointScalarField::MinimumLimit => match &mut joint.configuration {
            PhysicsJointConfiguration::Distance(value) => {
                value.minimum_distance = scalar.max(0.0).min(value.maximum_distance)
            }
            PhysicsJointConfiguration::Hinge(value) => {
                value.minimum_angle = scalar.min(value.maximum_angle)
            }
            PhysicsJointConfiguration::Slider(value) => {
                value.minimum_distance = scalar.min(value.maximum_distance)
            }
            PhysicsJointConfiguration::Cone(value) => {
                value.minimum_twist_angle = scalar.min(value.maximum_twist_angle)
            }
            _ => {}
        },
        JointScalarField::MaximumLimit => match &mut joint.configuration {
            PhysicsJointConfiguration::Distance(value) => {
                value.maximum_distance = scalar.max(0.0).max(value.minimum_distance)
            }
            PhysicsJointConfiguration::Hinge(value) => {
                value.maximum_angle = scalar.max(value.minimum_angle)
            }
            PhysicsJointConfiguration::Slider(value) => {
                value.maximum_distance = scalar.max(value.minimum_distance)
            }
            PhysicsJointConfiguration::Cone(value) => {
                value.maximum_twist_angle = scalar.max(value.minimum_twist_angle)
            }
            _ => {}
        },
        JointScalarField::HalfConeAngle => {
            if let PhysicsJointConfiguration::Cone(value) = &mut joint.configuration {
                value.half_cone_angle = scalar.max(0.0);
            }
        }
        JointScalarField::SpringFrequency | JointScalarField::SpringDamping => {
            let Some(mut spring) = joint_spring(&joint.configuration).copied() else {
                return;
            };
            if field == JointScalarField::SpringFrequency {
                spring.frequency = scalar.max(0.0);
            } else {
                spring.damping = scalar.max(0.0);
            }
            match &mut joint.configuration {
                PhysicsJointConfiguration::Distance(value) => value.spring = spring,
                PhysicsJointConfiguration::Hinge(value) => value.spring = spring,
                PhysicsJointConfiguration::Slider(value) => value.spring = spring,
                PhysicsJointConfiguration::Cone(value) => value.spring = spring,
                PhysicsJointConfiguration::SixDof(value) => value.spring = spring,
                _ => {}
            }
        }
        JointScalarField::BreakForce => joint.break_force = scalar.max(0.0),
        JointScalarField::BreakTorque => joint.break_torque = scalar.max(0.0),
    }
}

fn joint_spring(configuration: &PhysicsJointConfiguration) -> Option<&PhysicsJointSpring> {
    match configuration {
        PhysicsJointConfiguration::Distance(value) => Some(&value.spring),
        PhysicsJointConfiguration::Hinge(value) => Some(&value.spring),
        PhysicsJointConfiguration::Slider(value) => Some(&value.spring),
        PhysicsJointConfiguration::Cone(value) => Some(&value.spring),
        PhysicsJointConfiguration::SixDof(value) => Some(&value.spring),
        _ => None,
    }
}

fn joint_motor(joint: &PhysicsJoint, slot: MotorSlot) -> Option<&PhysicsJointMotor> {
    match &joint.configuration {
        PhysicsJointConfiguration::Hinge(value) => match slot {
            MotorSlot::Primary => Some(&value.motor),
            MotorSlot::Angular => None,
        },
        PhysicsJointConfiguration::Slider(value) => match slot {
            MotorSlot::Primary => Some(&value.motor),
            MotorSlot::Angular => None,
        },
        PhysicsJointConfiguration::SixDof(value) => match slot {
            MotorSlot::Primary => Some(&value.linear_motor),
            MotorSlot::Angular => Some(&value.angular_motor),
        },
        _ => None,
    }
}

fn update_joint_motor(
    joint: &mut PhysicsJoint,
    slot: MotorSlot,
    update: impl FnOnce(&mut PhysicsJointMotor),
) {
    match &mut joint.configuration {
        PhysicsJointConfiguration::Hinge(value) => {
            if matches!(slot, MotorSlot::Primary) {
                update(&mut value.motor);
            }
        }
        PhysicsJointConfiguration::Slider(value) => {
            if matches!(slot, MotorSlot::Primary) {
                update(&mut value.motor);
            }
        }
        PhysicsJointConfiguration::SixDof(value) => match slot {
            MotorSlot::Primary => update(&mut value.linear_motor),
            MotorSlot::Angular => update(&mut value.angular_motor),
        },
        _ => {}
    }
}
