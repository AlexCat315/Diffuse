//! `Codecs/References.swift` — physics constraints and ragdoll rigs.
//!
//! Both codecs encode *references* to other entities: a constraint stores the
//! document-local indices of its endpoints, and a ragdoll stores the indices of
//! its body and joint entities. The caller supplies the index maps derived from
//! `ComponentEncodeContext` / `ComponentDecodeContext`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{
    integer, json_to_array, json_to_bool, json_to_dict, json_to_float, json_to_float_array,
    json_to_int, json_to_matrix, json_to_string, json_to_vec3, matrix_to_json, number, object,
    vec3_to_json,
};
use crate::components::core::value::ComponentValue;
use crate::entity_id::EntityID;
use crate::physics::joints::physics_joint::{Constraint, PhysicsJoint};
use crate::physics::joints::physics_joint_configuration::{
    ConeJointConfiguration, DistanceJointConfiguration, HingeJointConfiguration,
    PhysicsJointConfiguration, PhysicsJointKind, PhysicsJointMotor, PhysicsJointMotorMode,
    PhysicsJointSpring, SixDofJointConfiguration, SliderJointConfiguration,
};
use crate::physics::ragdoll::{Ragdoll, RagdollBoneMapping, RagdollMode};
use crate::physics::rigid_body::RigidBodyMotionType;

impl BuiltinComponentCodecs {
    /// Swift `serializeConstraint` — endpoints are already resolved list indices.
    pub fn serialize_constraint(
        component: &Constraint,
        entity_a: i64,
        entity_b: i64,
    ) -> BTreeMap<String, ComponentValue> {
        let mut result = object([
            (
                "type",
                ComponentValue::String(component.constraint_type().raw_value().to_string()),
            ),
            ("entityA", integer(entity_a)),
            ("entityB", integer(entity_b)),
            ("pivotA", vec3_to_json(component.pivot_a)),
            ("pivotB", vec3_to_json(component.pivot_b)),
            ("axisA", vec3_to_json(component.axis_a())),
            ("axisB", vec3_to_json(component.axis_b())),
            ("minLimit", number(component.min_limit())),
            ("maxLimit", number(component.max_limit())),
            ("isEnabled", ComponentValue::Bool(component.is_enabled)),
            ("breakForce", number(component.break_force)),
            ("breakTorque", number(component.break_torque)),
        ]);
        match &component.configuration {
            PhysicsJointConfiguration::Point | PhysicsJointConfiguration::Fixed { .. } => {}
            PhysicsJointConfiguration::Distance(value) => {
                store_spring(&mut result, &value.spring);
            }
            PhysicsJointConfiguration::Hinge(value) => {
                store_spring(&mut result, &value.spring);
                store_motor(&mut result, &value.motor, "motor");
            }
            PhysicsJointConfiguration::Slider(value) => {
                store_spring(&mut result, &value.spring);
                store_motor(&mut result, &value.motor, "motor");
            }
            PhysicsJointConfiguration::Cone(value) => {
                result.insert("halfConeAngle".to_string(), number(value.half_cone_angle));
                store_spring(&mut result, &value.spring);
            }
            PhysicsJointConfiguration::SixDof(value) => {
                result.insert(
                    "linearMinimum".to_string(),
                    vec3_to_json(value.linear_minimum),
                );
                result.insert(
                    "linearMaximum".to_string(),
                    vec3_to_json(value.linear_maximum),
                );
                result.insert(
                    "angularMinimum".to_string(),
                    vec3_to_json(value.angular_minimum),
                );
                result.insert(
                    "angularMaximum".to_string(),
                    vec3_to_json(value.angular_maximum),
                );
                store_spring(&mut result, &value.spring);
                store_motor(&mut result, &value.linear_motor, "motor");
                store_motor(&mut result, &value.angular_motor, "angularMotor");
            }
        }
        result
    }

    pub fn deserialize_constraint(
        document: &BTreeMap<String, ComponentValue>,
        entity_a: EntityID,
        entity_b: EntityID,
    ) -> Constraint {
        let kind = json_to_string(document.get("type"))
            .and_then(PhysicsJointKind::from_raw_value)
            .unwrap_or(PhysicsJointKind::PointToPoint);
        let axis_a = json_to_float_array(document.get("axisA"))
            .and_then(|values| json_to_vec3(&values))
            .unwrap_or(Float3::new(0.0, 1.0, 0.0));
        let axis_b = json_to_float_array(document.get("axisB"))
            .and_then(|values| json_to_vec3(&values))
            .unwrap_or(Float3::new(0.0, 1.0, 0.0));
        let minimum = json_to_float(document.get("minLimit")).unwrap_or(0.0);
        let maximum = json_to_float(document.get("maxLimit")).unwrap_or(0.0);
        let spring = PhysicsJointSpring::new(
            json_to_float(document.get("springFrequency")).unwrap_or(0.0),
            json_to_float(document.get("springDamping")).unwrap_or(0.0),
        );
        let motor = |prefix: &str| {
            PhysicsJointMotor::new(
                json_to_string(document.get(&format!("{prefix}Mode")))
                    .and_then(PhysicsJointMotorMode::from_raw_value)
                    .unwrap_or(PhysicsJointMotorMode::Disabled),
                json_to_float(document.get(&format!("{prefix}TargetPosition"))).unwrap_or(0.0),
                json_to_float(document.get(&format!("{prefix}TargetVelocity"))).unwrap_or(0.0),
                json_to_float(document.get(&format!("{prefix}MaxForce")))
                    .unwrap_or(PhysicsJointMotor::DEFAULT_MAX_FORCE),
            )
        };
        let configuration = match kind {
            PhysicsJointKind::PointToPoint => PhysicsJointConfiguration::Point,
            PhysicsJointKind::Fixed => PhysicsJointConfiguration::Fixed { axis_a, axis_b },
            PhysicsJointKind::Distance => {
                PhysicsJointConfiguration::Distance(DistanceJointConfiguration::new(
                    minimum, maximum, spring,
                ))
            }
            PhysicsJointKind::Hinge => {
                PhysicsJointConfiguration::Hinge(HingeJointConfiguration::new(
                    axis_a,
                    axis_b,
                    minimum,
                    maximum,
                    motor("motor"),
                    spring,
                ))
            }
            PhysicsJointKind::Slider => {
                PhysicsJointConfiguration::Slider(SliderJointConfiguration::new(
                    axis_a,
                    axis_b,
                    minimum,
                    maximum,
                    motor("motor"),
                    spring,
                ))
            }
            PhysicsJointKind::Cone => {
                PhysicsJointConfiguration::Cone(ConeJointConfiguration::new(
                    axis_a,
                    axis_b,
                    json_to_float(document.get("halfConeAngle"))
                        .unwrap_or(std::f32::consts::FRAC_PI_4),
                    minimum,
                    maximum,
                    spring,
                ))
            }
            PhysicsJointKind::SixDof => {
                PhysicsJointConfiguration::SixDof(SixDofJointConfiguration::new(
                    axis_a,
                    axis_b,
                    json_to_float_array(document.get("linearMinimum"))
                        .and_then(|values| json_to_vec3(&values))
                        .unwrap_or(Float3::ZERO),
                    json_to_float_array(document.get("linearMaximum"))
                        .and_then(|values| json_to_vec3(&values))
                        .unwrap_or(Float3::ZERO),
                    json_to_float_array(document.get("angularMinimum"))
                        .and_then(|values| json_to_vec3(&values))
                        .unwrap_or(Float3::ZERO),
                    json_to_float_array(document.get("angularMaximum"))
                        .and_then(|values| json_to_vec3(&values))
                        .unwrap_or(Float3::ZERO),
                    motor("motor"),
                    motor("angularMotor"),
                    spring,
                ))
            }
        };
        Constraint::new(
            configuration,
            entity_a,
            entity_b,
            json_to_float_array(document.get("pivotA"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            json_to_float_array(document.get("pivotB"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            json_to_bool(document.get("isEnabled")).unwrap_or(true),
            json_to_float(document.get("breakForce")).unwrap_or(PhysicsJoint::DEFAULT_BREAK_LIMIT),
            json_to_float(document.get("breakTorque")).unwrap_or(PhysicsJoint::DEFAULT_BREAK_LIMIT),
        )
    }

    /// Swift `serializeRagdoll` — bones whose body is not in the map are dropped.
    pub fn serialize_ragdoll(
        ragdoll: &Ragdoll,
        entity_index_map: &BTreeMap<EntityID, i64>,
    ) -> BTreeMap<String, ComponentValue> {
        let mut bones: Vec<ComponentValue> = Vec::new();
        for bone in &ragdoll.bones {
            let Some(body) = entity_index_map.get(&bone.body_entity) else {
                continue;
            };
            let mut result = object([
                (
                    "boneName",
                    ComponentValue::String(bone.bone_name.clone()),
                ),
                ("paletteIndex", integer(bone.palette_index)),
                ("bodyEntity", integer(*body)),
                ("bodyFromPalette", matrix_to_json(&bone.body_from_palette)),
                (
                    "simulatedMotionType",
                    ComponentValue::String(bone.simulated_motion_type.raw_value().to_string()),
                ),
                (
                    "isSimulationEnabled",
                    ComponentValue::Bool(bone.is_simulation_enabled),
                ),
                ("blendWeight", number(bone.blend_weight)),
            ]);
            if let Some(joint_entity) = bone
                .joint_entity
                .and_then(|entity| entity_index_map.get(&entity).copied())
            {
                result.insert("jointEntity".to_string(), integer(joint_entity));
            }
            bones.push(ComponentValue::Object(result));
        }
        object([
            (
                "mode",
                ComponentValue::String(ragdoll.mode.raw_value().to_string()),
            ),
            ("blendWeight", number(ragdoll.blend_weight)),
            ("isEnabled", ComponentValue::Bool(ragdoll.is_enabled)),
            ("bones", ComponentValue::Array(bones)),
        ])
    }

    /// Swift `deserializeRagdoll` — a bone without a resolvable body is dropped.
    pub fn deserialize_ragdoll(
        document: &BTreeMap<String, ComponentValue>,
        entity_map: &BTreeMap<i64, EntityID>,
    ) -> Ragdoll {
        let mut bones: Vec<RagdollBoneMapping> = Vec::new();
        for raw in json_to_array(document.get("bones")).unwrap_or(&[]) {
            let Some(bone) = json_to_dict(Some(raw)) else {
                continue;
            };
            let Some(body_index) = json_to_int(bone.get("bodyEntity")) else {
                continue;
            };
            let Some(body_entity) = entity_map.get(&body_index).copied() else {
                continue;
            };
            let joint_entity = json_to_int(bone.get("jointEntity"))
                .and_then(|index| entity_map.get(&index).copied());
            bones.push(RagdollBoneMapping::with_mapping(
                json_to_string(bone.get("boneName")).unwrap_or(""),
                json_to_int(bone.get("paletteIndex")).unwrap_or(0),
                body_entity,
                joint_entity,
                json_to_float_array(bone.get("bodyFromPalette"))
                    .and_then(|values| json_to_matrix(&values))
                    .unwrap_or(MATRIX_IDENTITY_FLOAT4X4),
                json_to_string(bone.get("simulatedMotionType"))
                    .and_then(RigidBodyMotionType::from_raw_value)
                    .unwrap_or(RigidBodyMotionType::Dynamic),
                json_to_bool(bone.get("isSimulationEnabled")).unwrap_or(true),
                json_to_float(bone.get("blendWeight")).unwrap_or(1.0),
            ));
        }
        Ragdoll::new(
            json_to_string(document.get("mode"))
                .and_then(RagdollMode::from_raw_value)
                .unwrap_or(RagdollMode::Animated),
            json_to_float(document.get("blendWeight")).unwrap_or(1.0),
            json_to_bool(document.get("isEnabled")).unwrap_or(true),
            bones,
        )
    }
}

fn store_spring(result: &mut BTreeMap<String, ComponentValue>, spring: &PhysicsJointSpring) {
    result.insert("springFrequency".to_string(), number(spring.frequency));
    result.insert("springDamping".to_string(), number(spring.damping));
}

fn store_motor(
    result: &mut BTreeMap<String, ComponentValue>,
    motor: &PhysicsJointMotor,
    prefix: &str,
) {
    result.insert(
        format!("{prefix}Mode"),
        ComponentValue::String(motor.mode.raw_value().to_string()),
    );
    result.insert(
        format!("{prefix}TargetPosition"),
        number(motor.target_position),
    );
    result.insert(
        format!("{prefix}TargetVelocity"),
        number(motor.target_velocity),
    );
    result.insert(format!("{prefix}MaxForce"), number(motor.max_force));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entity(index: u32) -> EntityID {
        EntityID::new(index, 0)
    }

    fn joint(configuration: PhysicsJointConfiguration) -> Constraint {
        Constraint::new(
            configuration,
            entity(0),
            entity(1),
            Float3::ZERO,
            Float3::ZERO,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        )
    }

    #[test]
    fn point_constraint_round_trips() {
        let value = joint(PhysicsJointConfiguration::Point);
        let document = BuiltinComponentCodecs::serialize_constraint(&value, 0, 1);
        assert_eq!(
            document.get("type"),
            Some(&ComponentValue::String("pointToPoint".to_string()))
        );
        let decoded = BuiltinComponentCodecs::deserialize_constraint(&document, entity(0), entity(1));
        assert_eq!(decoded.constraint_type(), PhysicsJointKind::PointToPoint);
        assert_eq!(decoded.axis_a(), Float3::new(0.0, 1.0, 0.0));
        assert_eq!(decoded.entity_b, entity(1));
    }

    #[test]
    fn six_dof_motor_keys_use_their_prefixes() {
        let value = joint(PhysicsJointConfiguration::SixDof(SixDofJointConfiguration::new(
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::ZERO,
            Float3::ZERO,
            Float3::ZERO,
            Float3::ZERO,
            PhysicsJointMotor::new(PhysicsJointMotorMode::Position, 1.0, 0.0, 10.0),
            PhysicsJointMotor::new(PhysicsJointMotorMode::Velocity, 0.0, 2.0, 20.0),
            PhysicsJointSpring::new(1.0, 0.5),
        )));
        let document = BuiltinComponentCodecs::serialize_constraint(&value, 3, 4);
        assert!(document.contains_key("motorMode"));
        assert!(document.contains_key("angularMotorMode"));
        assert!(document.contains_key("angularMotorMaxForce"));
    }

    #[test]
    fn ragdoll_drops_bones_without_resolvable_entities() {
        let bones = vec![
            RagdollBoneMapping::new("root", 0, entity(7)),
            RagdollBoneMapping::new("orphan", 1, entity(9)),
        ];
        let ragdoll = Ragdoll::new(RagdollMode::Simulated, 0.5, true, bones);
        let mut index_map = BTreeMap::new();
        index_map.insert(entity(7), 0);
        let document = BuiltinComponentCodecs::serialize_ragdoll(&ragdoll, &index_map);
        let encoded_bones = json_to_array(document.get("bones")).expect("bones");
        assert_eq!(encoded_bones.len(), 1);

        let mut entity_map = BTreeMap::new();
        entity_map.insert(0, entity(7));
        let decoded = BuiltinComponentCodecs::deserialize_ragdoll(&document, &entity_map);
        assert_eq!(decoded.bones.len(), 1);
        assert_eq!(decoded.bones[0].bone_name, "root");
        assert_eq!(decoded.mode, RagdollMode::Simulated);
    }
}
