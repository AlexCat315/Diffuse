//! `Codecs/Physics.swift` — rigid bodies, colliders, characters, vehicles,
//! deformables and destructibles.
//!
//! Every `deserialize_*` builds its component through the Rust constructor rather
//! than a struct literal, so the clamping that lives in those initializers keeps
//! applying on the load path exactly as Swift's memberwise `init` did.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{
    integer, json_to_array, json_to_bool, json_to_dict, json_to_float, json_to_float_array,
    json_to_int, json_to_string, json_to_vec3, json_to_vec4, number, object, vec3_to_json,
    vec4_to_json,
};
use crate::components::core::value::ComponentValue;
use crate::components::editing::ComponentEditError;
use crate::components::editing::topology_input::{
    normalize_resource_id, validate_vertex_indices, vertex_indices_value,
};
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::{Collider, ColliderShape, ColliderShapeInstance, PhysicsMaterial};
use crate::physics::destruction::Destructible;
use crate::physics::rigid_body::{
    PhysicsKinematicTarget, RigidBody, RigidBodyAxisLocks, RigidBodyMassMode,
    RigidBodyMotionQuality, RigidBodyMotionType, RigidBodyOptions,
};
use crate::physics::soft_bodies::cloth::{Cloth, ClothBendType};
use crate::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::physics::vehicles::vehicle_controller_configuration::{
    MotorcycleVehicleConfiguration, TrackedVehicleConfiguration, VehicleControllerConfiguration,
    VehicleControllerKind, VehicleTrackConfiguration,
};
use crate::physics::vehicles::vehicle_powertrain::{
    VehicleEngineConfiguration, VehicleTransmissionConfiguration,
};
use crate::physics::vehicles::vehicle_wheel_configuration::{
    VehicleAntiRollBarConfiguration, VehicleDifferentialConfiguration, VehicleTransmissionMode,
    VehicleWheelConfiguration,
};

impl BuiltinComponentCodecs {
    // MARK: - Rigid body

    pub fn serialize_rigid_body(component: &RigidBody) -> BTreeMap<String, ComponentValue> {
        let mut document = object([
            (
                "motionType",
                ComponentValue::String(component.motion_type.raw_value().to_string()),
            ),
            ("mass", number(component.mass)),
            (
                "massMode",
                ComponentValue::String(component.mass_mode.raw_value().to_string()),
            ),
            ("linearVelocity", vec3_to_json(component.linear_velocity)),
            ("angularVelocity", vec3_to_json(component.angular_velocity)),
            ("accumulatedForce", vec3_to_json(component.accumulated_force)),
            (
                "accumulatedTorque",
                vec3_to_json(component.accumulated_torque),
            ),
            (
                "accumulatedLinearImpulse",
                vec3_to_json(component.accumulated_linear_impulse),
            ),
            (
                "accumulatedAngularImpulse",
                vec3_to_json(component.accumulated_angular_impulse),
            ),
            ("linearDamping", number(component.linear_damping)),
            ("angularDamping", number(component.angular_damping)),
            ("gravityScale", number(component.gravity_scale)),
            ("allowSleep", ComponentValue::Bool(component.allow_sleep)),
            ("isSleeping", ComponentValue::Bool(component.is_sleeping)),
            (
                "continuousCollisionDetection",
                ComponentValue::Bool(component.continuous_collision_detection),
            ),
            ("axisLocks", integer(i64::from(component.axis_locks.raw_value))),
            ("maxLinearVelocity", number(component.max_linear_velocity)),
            ("maxAngularVelocity", number(component.max_angular_velocity)),
            (
                "motionQuality",
                ComponentValue::String(component.motion_quality.raw_value().to_string()),
            ),
        ]);
        if let Some(center_of_mass) = component.center_of_mass_override {
            document.insert("centerOfMassOverride".to_string(), vec3_to_json(center_of_mass));
        }
        if let Some(inertia) = component.inertia_diagonal_override {
            document.insert("inertiaDiagonalOverride".to_string(), vec3_to_json(inertia));
        }
        if let Some(target) = component.kinematic_target {
            document.insert(
                "kinematicTarget".to_string(),
                ComponentValue::Object(object([
                    ("position", vec3_to_json(target.position)),
                    ("rotation", vec4_to_json(target.rotation)),
                ])),
            );
        }
        document
    }

    pub fn deserialize_rigid_body(document: &BTreeMap<String, ComponentValue>) -> RigidBody {
        RigidBody::new(RigidBodyOptions {
            motion_type: json_to_string(document.get("motionType"))
                .and_then(RigidBodyMotionType::from_raw_value)
                .unwrap_or(RigidBodyMotionType::Dynamic),
            mass: json_to_float(document.get("mass")).unwrap_or(1.0),
            mass_mode: json_to_string(document.get("massMode"))
                .and_then(RigidBodyMassMode::from_raw_value)
                .unwrap_or(RigidBodyMassMode::Mass),
            linear_velocity: json_to_float_array(document.get("linearVelocity"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            angular_velocity: json_to_float_array(document.get("angularVelocity"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            accumulated_force: json_to_float_array(document.get("accumulatedForce"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            accumulated_torque: json_to_float_array(document.get("accumulatedTorque"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            accumulated_linear_impulse: json_to_float_array(
                document.get("accumulatedLinearImpulse"),
            )
            .and_then(|values| json_to_vec3(&values))
            .unwrap_or(Float3::ZERO),
            accumulated_angular_impulse: json_to_float_array(
                document.get("accumulatedAngularImpulse"),
            )
            .and_then(|values| json_to_vec3(&values))
            .unwrap_or(Float3::ZERO),
            gravity_scale: json_to_float(document.get("gravityScale")).unwrap_or(1.0),
            linear_damping: json_to_float(document.get("linearDamping")).unwrap_or(0.04),
            angular_damping: json_to_float(document.get("angularDamping")).unwrap_or(0.04),
            allow_sleep: json_to_bool(document.get("allowSleep")).unwrap_or(true),
            is_sleeping: json_to_bool(document.get("isSleeping")).unwrap_or(false),
            continuous_collision_detection: json_to_bool(
                document.get("continuousCollisionDetection"),
            )
            .unwrap_or(false),
            center_of_mass_override: json_to_float_array(document.get("centerOfMassOverride"))
                .and_then(|values| json_to_vec3(&values)),
            inertia_diagonal_override: json_to_float_array(document.get("inertiaDiagonalOverride"))
                .and_then(|values| json_to_vec3(&values)),
            axis_locks: RigidBodyAxisLocks::new(clamping_u8(
                json_to_int(document.get("axisLocks")).unwrap_or(0),
            )),
            max_linear_velocity: json_to_float(document.get("maxLinearVelocity")).unwrap_or(500.0),
            max_angular_velocity: json_to_float(document.get("maxAngularVelocity"))
                .unwrap_or(0.25 * std::f32::consts::PI * 60.0),
            motion_quality: json_to_string(document.get("motionQuality"))
                .and_then(RigidBodyMotionQuality::from_raw_value)
                .unwrap_or(RigidBodyMotionQuality::Discrete),
            kinematic_target: json_to_dict(document.get("kinematicTarget")).and_then(|target| {
                let position = json_to_float_array(target.get("position"))
                    .and_then(|values| json_to_vec3(&values))?;
                let rotation = json_to_float_array(target.get("rotation"))
                    .and_then(|values| json_to_vec4(&values))
                    .unwrap_or(Float4::new(0.0, 0.0, 0.0, 1.0));
                Some(PhysicsKinematicTarget::with_rotation(position, rotation))
            }),
        })
    }

    // MARK: - Collider

    pub fn serialize_collider(component: &Collider) -> BTreeMap<String, ComponentValue> {
        let mut document = object([
            ("isTrigger", ComponentValue::Bool(component.is_trigger)),
            ("layerID", integer(i64::from(component.layer_id))),
            ("layerMask", integer(i64::from(component.layer_mask))),
            ("friction", number(component.material.friction)),
            ("restitution", number(component.material.restitution)),
            ("density", number(component.material.density)),
        ]);
        let shapes = component
            .shapes
            .iter()
            .map(|instance| {
                let mut encoded = BuiltinComponentCodecs::serialize_collider_shape(&instance.shape);
                encoded.insert(
                    "localPosition".to_string(),
                    vec3_to_json(instance.local_position),
                );
                encoded.insert(
                    "localRotation".to_string(),
                    vec4_to_json(instance.local_rotation),
                );
                encoded.insert("localScale".to_string(), vec3_to_json(instance.local_scale));
                ComponentValue::Object(encoded)
            })
            .collect();
        document.insert("shapes".to_string(), ComponentValue::Array(shapes));

        let shape = component.shape();
        let center = shape.center();
        document.insert(
            "shape".to_string(),
            ComponentValue::String(shape.kind().raw_value().to_string()),
        );
        match &shape {
            ColliderShape::Box { half_extents, .. } => {
                document.insert("halfExtents".to_string(), vec3_to_json(*half_extents));
            }
            ColliderShape::Sphere { radius, .. } => {
                document.insert("radius".to_string(), number(*radius));
            }
            ColliderShape::Capsule {
                radius,
                half_height,
                ..
            }
            | ColliderShape::Cylinder {
                radius,
                half_height,
                ..
            } => {
                document.insert("radius".to_string(), number(*radius));
                document.insert("halfHeight".to_string(), number(*half_height));
            }
            ColliderShape::HeightField { resource_id, .. }
            | ColliderShape::Mesh { resource_id, .. }
            | ColliderShape::Convex { resource_id, .. } => {
                document.insert(
                    "resourceID".to_string(),
                    ComponentValue::String(resource_id.clone().unwrap_or_default()),
                );
            }
        }
        document.insert("center".to_string(), vec3_to_json(center));
        document
    }

    pub fn serialize_collider_shape(
        shape: &ColliderShape,
    ) -> BTreeMap<String, ComponentValue> {
        let mut document = object([("center", vec3_to_json(shape.center()))]);
        document.insert(
            "shape".to_string(),
            ComponentValue::String(shape.kind().raw_value().to_string()),
        );
        match shape {
            ColliderShape::Box { half_extents, .. } => {
                document.insert("halfExtents".to_string(), vec3_to_json(*half_extents));
            }
            ColliderShape::Sphere { radius, .. } => {
                document.insert("radius".to_string(), number(*radius));
            }
            ColliderShape::Capsule {
                radius,
                half_height,
                ..
            }
            | ColliderShape::Cylinder {
                radius,
                half_height,
                ..
            } => {
                document.insert("radius".to_string(), number(*radius));
                document.insert("halfHeight".to_string(), number(*half_height));
            }
            ColliderShape::HeightField { resource_id, .. }
            | ColliderShape::Mesh { resource_id, .. }
            | ColliderShape::Convex { resource_id, .. } => {
                document.insert(
                    "resourceID".to_string(),
                    ComponentValue::String(resource_id.clone().unwrap_or_default()),
                );
            }
        }
        document
    }

    pub fn deserialize_collider(document: &BTreeMap<String, ComponentValue>) -> Collider {
        let center = json_to_float_array(document.get("center"))
            .and_then(|values| json_to_vec3(&values))
            .unwrap_or(Float3::ZERO);
        let shape = match json_to_string(document.get("shape")).unwrap_or("box") {
            "sphere" => ColliderShape::Sphere {
                radius: json_to_float(document.get("radius")).unwrap_or(0.5),
                center,
            },
            "capsule" => ColliderShape::Capsule {
                radius: json_to_float(document.get("radius")).unwrap_or(0.5),
                half_height: json_to_float(document.get("halfHeight")).unwrap_or(1.0),
                center,
            },
            "cylinder" => ColliderShape::Cylinder {
                radius: json_to_float(document.get("radius")).unwrap_or(0.5),
                half_height: json_to_float(document.get("halfHeight")).unwrap_or(0.5),
                center,
            },
            "heightField" => ColliderShape::HeightField {
                resource_id: json_to_string(document.get("resourceID")).map(str::to_string),
                center,
            },
            "mesh" => ColliderShape::Mesh {
                resource_id: json_to_string(document.get("resourceID")).map(str::to_string),
                center,
            },
            "convex" => ColliderShape::Convex {
                resource_id: json_to_string(document.get("resourceID")).map(str::to_string),
                center,
            },
            _ => ColliderShape::Box {
                half_extents: json_to_float_array(document.get("halfExtents"))
                    .and_then(|values| json_to_vec3(&values))
                    .unwrap_or(Float3::splat(0.5)),
                center,
            },
        };
        let instances = json_to_array(document.get("shapes")).map(|values| {
            values
                .iter()
                .filter_map(|value| {
                    let encoded = json_to_dict(Some(value))?;
                    let local_position = json_to_float_array(encoded.get("localPosition"))
                        .and_then(|values| json_to_vec3(&values))
                        .unwrap_or(Float3::ZERO);
                    let local_rotation = json_to_float_array(encoded.get("localRotation"))
                        .and_then(|values| json_to_vec4(&values))
                        .unwrap_or(Float4::new(0.0, 0.0, 0.0, 1.0));
                    let local_scale = json_to_float_array(encoded.get("localScale"))
                        .and_then(|values| json_to_vec3(&values))
                        .unwrap_or(Float3::splat(1.0));
                    Some(ColliderShapeInstance::with_transform(
                        BuiltinComponentCodecs::deserialize_collider_shape(encoded),
                        local_position,
                        local_rotation,
                        local_scale,
                    ))
                })
                .collect::<Vec<_>>()
        });
        Collider {
            shapes: instances
                .unwrap_or_else(|| vec![ColliderShapeInstance::new(shape)]),
            is_trigger: json_to_bool(document.get("isTrigger")).unwrap_or(false),
            layer_id: clamping_u16(json_to_int(document.get("layerID")).unwrap_or(0)),
            layer_mask: clamping_u16(
                json_to_int(document.get("layerMask")).unwrap_or(i64::from(u16::MAX)),
            ),
            material: PhysicsMaterial::new(
                json_to_float(document.get("friction")).unwrap_or(0.6),
                json_to_float(document.get("restitution")).unwrap_or(0.0),
                json_to_float(document.get("density")).unwrap_or(1.0),
            ),
        }
    }

    pub fn deserialize_collider_shape(
        document: &BTreeMap<String, ComponentValue>,
    ) -> ColliderShape {
        let center = json_to_float_array(document.get("center"))
            .and_then(|values| json_to_vec3(&values))
            .unwrap_or(Float3::ZERO);
        match json_to_string(document.get("shape")).unwrap_or("box") {
            "sphere" => ColliderShape::Sphere {
                radius: json_to_float(document.get("radius")).unwrap_or(0.5),
                center,
            },
            "capsule" => ColliderShape::Capsule {
                radius: json_to_float(document.get("radius")).unwrap_or(0.5),
                half_height: json_to_float(document.get("halfHeight")).unwrap_or(0.5),
                center,
            },
            "cylinder" => ColliderShape::Cylinder {
                radius: json_to_float(document.get("radius")).unwrap_or(0.5),
                half_height: json_to_float(document.get("halfHeight")).unwrap_or(0.5),
                center,
            },
            "heightField" => ColliderShape::HeightField {
                resource_id: json_to_string(document.get("resourceID")).map(str::to_string),
                center,
            },
            "mesh" => ColliderShape::Mesh {
                resource_id: json_to_string(document.get("resourceID")).map(str::to_string),
                center,
            },
            "convex" => ColliderShape::Convex {
                resource_id: json_to_string(document.get("resourceID")).map(str::to_string),
                center,
            },
            _ => ColliderShape::Box {
                half_extents: json_to_float_array(document.get("halfExtents"))
                    .and_then(|values| json_to_vec3(&values))
                    .unwrap_or(Float3::splat(0.5)),
                center,
            },
        }
    }

    // MARK: - Character controller

    pub fn serialize_character_controller(
        component: &CharacterController,
    ) -> BTreeMap<String, ComponentValue> {
        object([
            ("radius", number(component.radius)),
            (
                "standingHalfHeight",
                number(component.standing_half_height),
            ),
            (
                "crouchingHalfHeight",
                number(component.crouching_half_height),
            ),
            ("center", vec3_to_json(component.center)),
            ("maxSlopeDegrees", number(component.max_slope_degrees)),
            ("stepHeight", number(component.step_height)),
            ("skinWidth", number(component.skin_width)),
            ("mass", number(component.mass)),
            ("maxStrength", number(component.max_strength)),
            ("gravityScale", number(component.gravity_scale)),
            ("layerID", integer(i64::from(component.layer_id))),
            ("layerMask", integer(i64::from(component.layer_mask))),
        ])
    }

    pub fn deserialize_character_controller(
        document: &BTreeMap<String, ComponentValue>,
    ) -> CharacterController {
        CharacterController::new(
            json_to_float(document.get("radius")).unwrap_or(0.4),
            json_to_float(document.get("standingHalfHeight")).unwrap_or(0.6),
            json_to_float(document.get("crouchingHalfHeight")).unwrap_or(0.25),
            json_to_float_array(document.get("center"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            json_to_float(document.get("maxSlopeDegrees")).unwrap_or(50.0),
            json_to_float(document.get("stepHeight")).unwrap_or(0.4),
            json_to_float(document.get("skinWidth")).unwrap_or(0.02),
            json_to_float(document.get("mass")).unwrap_or(70.0),
            json_to_float(document.get("maxStrength")).unwrap_or(100.0),
            json_to_float(document.get("gravityScale")).unwrap_or(1.0),
            clamping_u16(json_to_int(document.get("layerID")).unwrap_or(0)),
            clamping_u16(json_to_int(document.get("layerMask")).unwrap_or(i64::from(u16::MAX))),
        )
    }

    // MARK: - Vehicle

    pub fn serialize_vehicle(vehicle: &Vehicle) -> BTreeMap<String, ComponentValue> {
        let controller = match &vehicle.controller {
            VehicleControllerConfiguration::Wheeled => {
                object([("kind", integer(i64::from(VehicleControllerKind::Wheeled.raw_value())))])
            }
            VehicleControllerConfiguration::Tracked(configuration) => object([
                (
                    "kind",
                    integer(i64::from(VehicleControllerKind::Tracked.raw_value())),
                ),
                (
                    "leftTrack",
                    ComponentValue::Object(serialize_track(&configuration.left_track)),
                ),
                (
                    "rightTrack",
                    ComponentValue::Object(serialize_track(&configuration.right_track)),
                ),
                (
                    "longitudinalFriction",
                    number(configuration.longitudinal_friction),
                ),
                ("lateralFriction", number(configuration.lateral_friction)),
            ]),
            VehicleControllerConfiguration::Motorcycle(configuration) => object([
                (
                    "kind",
                    integer(i64::from(VehicleControllerKind::Motorcycle.raw_value())),
                ),
                ("maxLeanAngle", number(configuration.max_lean_angle)),
                (
                    "leanSpringConstant",
                    number(configuration.lean_spring_constant),
                ),
                (
                    "leanSpringDamping",
                    number(configuration.lean_spring_damping),
                ),
                (
                    "leanSpringIntegrationCoefficient",
                    number(configuration.lean_spring_integration_coefficient),
                ),
                (
                    "leanSpringIntegrationCoefficientDecay",
                    number(configuration.lean_spring_integration_coefficient_decay),
                ),
                (
                    "leanSmoothingFactor",
                    number(configuration.lean_smoothing_factor),
                ),
                (
                    "isLeanControllerEnabled",
                    ComponentValue::Bool(configuration.is_lean_controller_enabled),
                ),
                (
                    "isLeanSteeringLimitEnabled",
                    ComponentValue::Bool(configuration.is_lean_steering_limit_enabled),
                ),
            ]),
        };

        let wheels = vehicle
            .wheels
            .iter()
            .map(|wheel| {
                ComponentValue::Object(object([
                    ("position", vec3_to_json(wheel.position)),
                    (
                        "suspensionDirection",
                        vec3_to_json(wheel.suspension_direction),
                    ),
                    ("steeringAxis", vec3_to_json(wheel.steering_axis)),
                    ("wheelUp", vec3_to_json(wheel.wheel_up)),
                    ("wheelForward", vec3_to_json(wheel.wheel_forward)),
                    ("suspensionMinLength", number(wheel.suspension_min_length)),
                    ("suspensionMaxLength", number(wheel.suspension_max_length)),
                    (
                        "suspensionPreloadLength",
                        number(wheel.suspension_preload_length),
                    ),
                    ("suspensionFrequency", number(wheel.suspension_frequency)),
                    ("suspensionDamping", number(wheel.suspension_damping)),
                    ("radius", number(wheel.radius)),
                    ("width", number(wheel.width)),
                    ("inertia", number(wheel.inertia)),
                    ("angularDamping", number(wheel.angular_damping)),
                    ("maxSteerAngle", number(wheel.max_steer_angle)),
                    ("maxBrakeTorque", number(wheel.max_brake_torque)),
                    ("maxHandBrakeTorque", number(wheel.max_hand_brake_torque)),
                ]))
            })
            .collect();

        let differentials = vehicle
            .differentials
            .iter()
            .map(|differential| {
                ComponentValue::Object(object([
                    ("leftWheel", integer(differential.left_wheel)),
                    ("rightWheel", integer(differential.right_wheel)),
                    ("differentialRatio", number(differential.differential_ratio)),
                    ("leftRightSplit", number(differential.left_right_split)),
                    ("limitedSlipRatio", number(differential.limited_slip_ratio)),
                    ("engineTorqueRatio", number(differential.engine_torque_ratio)),
                ]))
            })
            .collect();

        let anti_roll_bars = vehicle
            .anti_roll_bars
            .iter()
            .map(|bar| {
                ComponentValue::Object(object([
                    ("leftWheel", integer(bar.left_wheel)),
                    ("rightWheel", integer(bar.right_wheel)),
                    ("stiffness", number(bar.stiffness)),
                ]))
            })
            .collect();

        object([
            ("isEnabled", ComponentValue::Bool(vehicle.is_enabled)),
            ("controller", ComponentValue::Object(controller)),
            ("up", vec3_to_json(vehicle.up)),
            ("forward", vec3_to_json(vehicle.forward)),
            ("maxPitchRollAngle", number(vehicle.max_pitch_roll_angle)),
            (
                "engine",
                ComponentValue::Object(object([
                    ("maxTorque", number(vehicle.engine.max_torque)),
                    ("minRPM", number(vehicle.engine.min_rpm)),
                    ("maxRPM", number(vehicle.engine.max_rpm)),
                    ("inertia", number(vehicle.engine.inertia)),
                    ("angularDamping", number(vehicle.engine.angular_damping)),
                ])),
            ),
            (
                "transmission",
                ComponentValue::Object(object([
                    (
                        "mode",
                        integer(i64::from(vehicle.transmission.mode.raw_value())),
                    ),
                    (
                        "gearRatios",
                        ComponentValue::Array(
                            vehicle
                                .transmission
                                .gear_ratios
                                .iter()
                                .map(|value| number(*value))
                                .collect(),
                        ),
                    ),
                    (
                        "reverseGearRatios",
                        ComponentValue::Array(
                            vehicle
                                .transmission
                                .reverse_gear_ratios
                                .iter()
                                .map(|value| number(*value))
                                .collect(),
                        ),
                    ),
                    ("switchTime", number(vehicle.transmission.switch_time)),
                    (
                        "clutchReleaseTime",
                        number(vehicle.transmission.clutch_release_time),
                    ),
                    ("switchLatency", number(vehicle.transmission.switch_latency)),
                    ("shiftUpRPM", number(vehicle.transmission.shift_up_rpm)),
                    ("shiftDownRPM", number(vehicle.transmission.shift_down_rpm)),
                    ("clutchStrength", number(vehicle.transmission.clutch_strength)),
                ])),
            ),
            ("wheels", ComponentValue::Array(wheels)),
            ("differentials", ComponentValue::Array(differentials)),
            ("antiRollBars", ComponentValue::Array(anti_roll_bars)),
        ])
    }

    pub fn deserialize_vehicle(document: &BTreeMap<String, ComponentValue>) -> Vehicle {
        let default_vehicle = Vehicle::default();
        let controller_document = json_to_dict(document.get("controller"));
        let engine_document = json_to_dict(document.get("engine"));
        let transmission_document = json_to_dict(document.get("transmission"));

        let wheels = json_to_array(document.get("wheels"))
            .map(|values| {
                values
                    .iter()
                    .filter_map(|raw| {
                        let wheel = json_to_dict(Some(raw))?;
                        Some(VehicleWheelConfiguration::new(
                            json_to_float_array(wheel.get("position"))
                                .and_then(|values| json_to_vec3(&values))
                                .unwrap_or(Float3::ZERO),
                            json_to_float_array(wheel.get("suspensionDirection"))
                                .and_then(|values| json_to_vec3(&values))
                                .unwrap_or(Float3::new(0.0, -1.0, 0.0)),
                            json_to_float_array(wheel.get("steeringAxis"))
                                .and_then(|values| json_to_vec3(&values))
                                .unwrap_or(Float3::new(0.0, 1.0, 0.0)),
                            json_to_float_array(wheel.get("wheelUp"))
                                .and_then(|values| json_to_vec3(&values))
                                .unwrap_or(Float3::new(0.0, 1.0, 0.0)),
                            json_to_float_array(wheel.get("wheelForward"))
                                .and_then(|values| json_to_vec3(&values))
                                .unwrap_or(Float3::new(0.0, 0.0, 1.0)),
                            json_to_float(wheel.get("suspensionMinLength")).unwrap_or(0.2),
                            json_to_float(wheel.get("suspensionMaxLength")).unwrap_or(0.5),
                            json_to_float(wheel.get("suspensionPreloadLength")).unwrap_or(0.0),
                            json_to_float(wheel.get("suspensionFrequency")).unwrap_or(1.5),
                            json_to_float(wheel.get("suspensionDamping")).unwrap_or(0.5),
                            json_to_float(wheel.get("radius")).unwrap_or(0.35),
                            json_to_float(wheel.get("width")).unwrap_or(0.2),
                            json_to_float(wheel.get("inertia")).unwrap_or(0.9),
                            json_to_float(wheel.get("angularDamping")).unwrap_or(0.2),
                            json_to_float(wheel.get("maxSteerAngle")).unwrap_or(0.0),
                            json_to_float(wheel.get("maxBrakeTorque")).unwrap_or(1_500.0),
                            json_to_float(wheel.get("maxHandBrakeTorque")).unwrap_or(0.0),
                        ))
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|| default_vehicle.wheels.clone());

        let differentials = json_to_array(document.get("differentials"))
            .map(|values| {
                values
                    .iter()
                    .filter_map(|raw| {
                        let differential = json_to_dict(Some(raw))?;
                        let left = json_to_int(differential.get("leftWheel"))?;
                        let right = json_to_int(differential.get("rightWheel"))?;
                        let mut value = VehicleDifferentialConfiguration::new(left, right);
                        value.differential_ratio =
                            json_to_float(differential.get("differentialRatio")).unwrap_or(3.42);
                        value.left_right_split =
                            json_to_float(differential.get("leftRightSplit")).unwrap_or(0.5);
                        value.limited_slip_ratio =
                            json_to_float(differential.get("limitedSlipRatio")).unwrap_or(1.4);
                        value.engine_torque_ratio =
                            json_to_float(differential.get("engineTorqueRatio")).unwrap_or(1.0);
                        Some(value.validated())
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|| default_vehicle.differentials.clone());

        let anti_roll_bars = json_to_array(document.get("antiRollBars"))
            .map(|values| {
                values
                    .iter()
                    .filter_map(|raw| {
                        let bar = json_to_dict(Some(raw))?;
                        let left = json_to_int(bar.get("leftWheel"))?;
                        let right = json_to_int(bar.get("rightWheel"))?;
                        let mut value = VehicleAntiRollBarConfiguration::new(left, right);
                        value.stiffness = json_to_float(bar.get("stiffness")).unwrap_or(1_000.0);
                        Some(value.validated())
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|| default_vehicle.anti_roll_bars.clone());

        let engine = VehicleEngineConfiguration::new(
            json_to_float(engine_document.and_then(|value| value.get("maxTorque"))).unwrap_or(500.0),
            json_to_float(engine_document.and_then(|value| value.get("minRPM"))).unwrap_or(1_000.0),
            json_to_float(engine_document.and_then(|value| value.get("maxRPM"))).unwrap_or(6_000.0),
            json_to_float(engine_document.and_then(|value| value.get("inertia"))).unwrap_or(0.5),
            json_to_float(engine_document.and_then(|value| value.get("angularDamping")))
                .unwrap_or(0.2),
        );

        let transmission = VehicleTransmissionConfiguration::new(
            VehicleTransmissionMode::from_raw_value(clamping_u8(
                json_to_int(transmission_document.and_then(|value| value.get("mode"))).unwrap_or(0),
            ))
            .unwrap_or(VehicleTransmissionMode::Automatic),
            json_to_float_array(transmission_document.and_then(|value| value.get("gearRatios")))
                .unwrap_or_else(|| vec![2.66, 1.78, 1.3, 1.0, 0.74]),
            json_to_float_array(
                transmission_document.and_then(|value| value.get("reverseGearRatios")),
            )
            .unwrap_or_else(|| vec![-2.9]),
            json_to_float(transmission_document.and_then(|value| value.get("switchTime")))
                .unwrap_or(0.5),
            json_to_float(transmission_document.and_then(|value| value.get("clutchReleaseTime")))
                .unwrap_or(0.3),
            json_to_float(transmission_document.and_then(|value| value.get("switchLatency")))
                .unwrap_or(0.5),
            json_to_float(transmission_document.and_then(|value| value.get("shiftUpRPM")))
                .unwrap_or(4_000.0),
            json_to_float(transmission_document.and_then(|value| value.get("shiftDownRPM")))
                .unwrap_or(2_000.0),
            json_to_float(transmission_document.and_then(|value| value.get("clutchStrength")))
                .unwrap_or(10.0),
        );

        let controller = match VehicleControllerKind::from_raw_value(clamping_u8(
            json_to_int(controller_document.and_then(|value| value.get("kind"))).unwrap_or(0),
        ))
        .unwrap_or(VehicleControllerKind::Wheeled)
        {
            VehicleControllerKind::Wheeled => VehicleControllerConfiguration::Wheeled,
            VehicleControllerKind::Tracked => {
                let fallback = match Vehicle::tracked_default().controller {
                    VehicleControllerConfiguration::Tracked(value) => value,
                    _ => panic!("Vehicle::tracked() must use a tracked controller"),
                };
                VehicleControllerConfiguration::Tracked(TrackedVehicleConfiguration::new(
                    deserialize_track(
                        json_to_dict(controller_document.and_then(|value| value.get("leftTrack"))),
                        fallback.left_track,
                    ),
                    deserialize_track(
                        json_to_dict(controller_document.and_then(|value| value.get("rightTrack"))),
                        fallback.right_track,
                    ),
                    json_to_float(
                        controller_document.and_then(|value| value.get("longitudinalFriction")),
                    )
                    .unwrap_or(fallback.longitudinal_friction),
                    json_to_float(
                        controller_document.and_then(|value| value.get("lateralFriction")),
                    )
                    .unwrap_or(fallback.lateral_friction),
                ))
            }
            VehicleControllerKind::Motorcycle => {
                VehicleControllerConfiguration::Motorcycle(MotorcycleVehicleConfiguration::new(
                    json_to_float(
                        controller_document.and_then(|value| value.get("maxLeanAngle")),
                    )
                    .unwrap_or(std::f32::consts::FRAC_PI_4),
                    json_to_float(
                        controller_document.and_then(|value| value.get("leanSpringConstant")),
                    )
                    .unwrap_or(5_000.0),
                    json_to_float(
                        controller_document.and_then(|value| value.get("leanSpringDamping")),
                    )
                    .unwrap_or(1_000.0),
                    json_to_float(controller_document.and_then(|value| {
                        value.get("leanSpringIntegrationCoefficient")
                    }))
                    .unwrap_or(0.0),
                    json_to_float(controller_document.and_then(|value| {
                        value.get("leanSpringIntegrationCoefficientDecay")
                    }))
                    .unwrap_or(4.0),
                    json_to_float(
                        controller_document.and_then(|value| value.get("leanSmoothingFactor")),
                    )
                    .unwrap_or(0.8),
                    json_to_bool(
                        controller_document.and_then(|value| value.get("isLeanControllerEnabled")),
                    )
                    .unwrap_or(true),
                    json_to_bool(controller_document.and_then(|value| {
                        value.get("isLeanSteeringLimitEnabled")
                    }))
                    .unwrap_or(true),
                ))
            }
        };

        Vehicle::new(
            controller,
            wheels,
            differentials,
            anti_roll_bars,
            engine,
            transmission,
            json_to_float_array(document.get("up"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::new(0.0, 1.0, 0.0)),
            json_to_float_array(document.get("forward"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::new(0.0, 0.0, 1.0)),
            json_to_float(document.get("maxPitchRollAngle")).unwrap_or(std::f32::consts::PI),
            json_to_bool(document.get("isEnabled")).unwrap_or(true),
        )
    }

    // MARK: - Soft bodies

    pub fn serialize_soft_body(body: &SoftBody) -> BTreeMap<String, ComponentValue> {
        object([
            ("vertexMass", number(body.vertex_mass)),
            ("pressure", number(body.pressure)),
            ("linearDamping", number(body.linear_damping)),
            ("friction", number(body.friction)),
            ("restitution", number(body.restitution)),
            ("gravityScale", number(body.gravity_scale)),
            ("vertexRadius", number(body.vertex_radius)),
            ("solverIterations", integer(body.solver_iterations)),
            ("maxLinearVelocity", number(body.max_linear_velocity)),
            ("layerID", integer(i64::from(body.layer_id))),
            ("layerMask", integer(i64::from(body.layer_mask))),
            ("allowSleep", ComponentValue::Bool(body.allow_sleep)),
            ("facesDoubleSided", ComponentValue::Bool(body.faces_double_sided)),
            ("selfCollision", ComponentValue::Bool(body.self_collision)),
            ("isEnabled", ComponentValue::Bool(body.is_enabled)),
        ])
    }

    pub fn deserialize_soft_body(document: &BTreeMap<String, ComponentValue>) -> SoftBody {
        SoftBody::new(
            json_to_float(document.get("vertexMass")).unwrap_or(1.0),
            json_to_float(document.get("pressure")).unwrap_or(0.0),
            json_to_float(document.get("linearDamping")).unwrap_or(0.1),
            json_to_float(document.get("friction")).unwrap_or(0.2),
            json_to_float(document.get("restitution")).unwrap_or(0.0),
            json_to_float(document.get("gravityScale")).unwrap_or(1.0),
            json_to_float(document.get("vertexRadius")).unwrap_or(0.02),
            json_to_int(document.get("solverIterations")).unwrap_or(5),
            json_to_float(document.get("maxLinearVelocity")).unwrap_or(500.0),
            clamping_u16(json_to_int(document.get("layerID")).unwrap_or(0)),
            clamping_u16(json_to_int(document.get("layerMask")).unwrap_or(i64::from(u16::MAX))),
            json_to_bool(document.get("allowSleep")).unwrap_or(true),
            json_to_bool(document.get("facesDoubleSided")).unwrap_or(true),
            json_to_bool(document.get("selfCollision")).unwrap_or(false),
            json_to_bool(document.get("isEnabled")).unwrap_or(true),
        )
    }

    pub fn serialize_cloth(cloth: &Cloth) -> BTreeMap<String, ComponentValue> {
        object([
            ("gridSizeX", integer(cloth.grid_size_x)),
            ("gridSizeZ", integer(cloth.grid_size_z)),
            ("spacing", number(cloth.spacing)),
            (
                "fixedVertexIndices",
                ComponentValue::Array(
                    cloth
                        .fixed_vertex_indices
                        .iter()
                        .map(|index| integer(*index))
                        .collect(),
                ),
            ),
            ("compliance", number(cloth.compliance)),
            ("shearCompliance", number(cloth.shear_compliance)),
            ("bendCompliance", number(cloth.bend_compliance)),
            ("bendType", integer(i64::from(cloth.bend_type.raw_value()))),
        ])
    }

    pub fn deserialize_cloth(document: &BTreeMap<String, ComponentValue>) -> Cloth {
        Cloth::new(
            json_to_int(document.get("gridSizeX")).unwrap_or(16),
            json_to_int(document.get("gridSizeZ")).unwrap_or(16),
            json_to_float(document.get("spacing")).unwrap_or(0.2),
            json_to_array(document.get("fixedVertexIndices"))
                .unwrap_or(&[])
                .iter()
                .filter_map(|value| json_to_int(Some(value)))
                .collect(),
            json_to_float(document.get("compliance")).unwrap_or(1.0e-5),
            json_to_float(document.get("shearCompliance")).unwrap_or(1.0e-5),
            json_to_float(document.get("bendCompliance")).unwrap_or(1.0e-5),
            ClothBendType::from_raw_value(clamping_u8(
                json_to_int(document.get("bendType")).unwrap_or(1),
            ))
            .unwrap_or(ClothBendType::Distance),
        )
    }

    pub fn serialize_soft_body_mesh(mesh: &SoftBodyMesh) -> BTreeMap<String, ComponentValue> {
        let mut result = object([
            (
                "fixedVertexIndices",
                ComponentValue::Array(
                    mesh.fixed_vertex_indices
                        .iter()
                        .map(|index| integer(*index))
                        .collect(),
                ),
            ),
            ("compliance", number(mesh.compliance)),
            ("shearCompliance", number(mesh.shear_compliance)),
            ("bendCompliance", number(mesh.bend_compliance)),
            ("volumeCompliance", number(mesh.volume_compliance)),
            ("bendType", integer(i64::from(mesh.bend_type.raw_value()))),
        ]);
        if let Some(resource_id) = &mesh.resource_id {
            result.insert("resourceID".to_string(), ComponentValue::String(resource_id.clone()));
        }
        result
    }

    pub fn deserialize_soft_body_mesh(
        document: &BTreeMap<String, ComponentValue>,
    ) -> SoftBodyMesh {
        SoftBodyMesh::new(
            json_to_string(document.get("resourceID")).map(str::to_string),
            json_to_array(document.get("fixedVertexIndices"))
                .unwrap_or(&[])
                .iter()
                .filter_map(|value| json_to_int(Some(value)))
                .collect(),
            json_to_float(document.get("compliance")).unwrap_or(1.0e-5),
            json_to_float(document.get("shearCompliance")).unwrap_or(1.0e-5),
            json_to_float(document.get("bendCompliance")).unwrap_or(1.0e-5),
            json_to_float(document.get("volumeCompliance")).unwrap_or(1.0e-6),
            ClothBendType::from_raw_value(clamping_u8(
                json_to_int(document.get("bendType")).unwrap_or(2),
            ))
            .unwrap_or(ClothBendType::Dihedral),
        )
    }

    // MARK: - Destructible

    pub fn serialize_destructible(destructible: &Destructible) -> BTreeMap<String, ComponentValue> {
        object([
            (
                "assetResourceID",
                ComponentValue::String(destructible.asset_resource_id.clone()),
            ),
            ("damageThreshold", number(destructible.damage_threshold)),
            ("impulseThreshold", number(destructible.impulse_threshold)),
            ("fragmentBudget", integer(destructible.fragment_budget)),
            (
                "maximumFragmentLifetimeSeconds",
                number(destructible.maximum_fragment_lifetime_seconds),
            ),
            (
                "sleepingRecycleDelaySeconds",
                number(destructible.sleeping_recycle_delay_seconds),
            ),
            ("separationImpulse", number(destructible.separation_impulse)),
            ("isEnabled", ComponentValue::Bool(destructible.is_enabled)),
        ])
    }

    pub fn deserialize_destructible(
        document: &BTreeMap<String, ComponentValue>,
    ) -> Destructible {
        Destructible::new(
            json_to_string(document.get("assetResourceID")).unwrap_or(""),
            json_to_float(document.get("damageThreshold")).unwrap_or(100.0),
            json_to_float(document.get("impulseThreshold")).unwrap_or(10.0),
            json_to_int(document.get("fragmentBudget")).unwrap_or(256),
            json_to_float(document.get("maximumFragmentLifetimeSeconds")).unwrap_or(30.0),
            json_to_float(document.get("sleepingRecycleDelaySeconds")).unwrap_or(5.0),
            json_to_float(document.get("separationImpulse")).unwrap_or(0.05),
            json_to_bool(document.get("isEnabled")).unwrap_or(true),
        )
    }

    // MARK: - Deformable topology edits

    /// Swift `normalizeClothChanges` (`Components/Editing/TopologyInput.swift`).
    ///
    /// Only a change that addresses `fixedVertexIndices` is rewritten: the merged
    /// result is validated as `[Int]`, decoded, and replaced with the cloth's
    /// canonical (filtered, sorted, de-duplicated) index list.
    pub fn normalize_cloth_changes(
        previous: &ComponentValue,
        changes: &ComponentValue,
    ) -> Result<ComponentValue, ComponentEditError> {
        let ComponentValue::Object(mut fields) = changes.clone() else {
            return Ok(changes.clone());
        };
        if !fields.contains_key("fixedVertexIndices") {
            return Ok(changes.clone());
        }
        let merged = previous.merging(changes)?;
        let path = [String::from("fixedVertexIndices")];
        validate_vertex_indices(merged.value_at(&path), "cloth")?;
        let Some(document) = merged.object_value() else {
            return Err(ComponentEditError::InvalidValue("cloth".to_string()));
        };
        let cloth = BuiltinComponentCodecs::deserialize_cloth(document);
        fields.insert(
            "fixedVertexIndices".to_string(),
            vertex_indices_value(&cloth.fixed_vertex_indices),
        );
        Ok(ComponentValue::Object(fields))
    }

    /// Swift `normalizeSoftBodyMeshChanges` (`Components/Editing/TopologyInput.swift`).
    pub fn normalize_soft_body_mesh_changes(
        previous: &ComponentValue,
        changes: &ComponentValue,
    ) -> Result<ComponentValue, ComponentEditError> {
        let ComponentValue::Object(mut fields) = changes.clone() else {
            return Ok(changes.clone());
        };
        let merged = previous.merging(changes)?;
        if fields.contains_key("fixedVertexIndices") {
            let path = [String::from("fixedVertexIndices")];
            validate_vertex_indices(merged.value_at(&path), "softBodyMesh")?;
            let Some(document) = merged.object_value() else {
                return Err(ComponentEditError::InvalidValue("softBodyMesh".to_string()));
            };
            let mesh = BuiltinComponentCodecs::deserialize_soft_body_mesh(document);
            fields.insert(
                "fixedVertexIndices".to_string(),
                vertex_indices_value(&mesh.fixed_vertex_indices),
            );
        }
        if let Some(value) = normalize_resource_id(fields.get("resourceID")) {
            fields.insert("resourceID".to_string(), value);
        }
        Ok(ComponentValue::Object(fields))
    }
}

fn serialize_track(track: &VehicleTrackConfiguration) -> BTreeMap<String, ComponentValue> {
    object([
        ("drivenWheel", integer(track.driven_wheel)),
        (
            "wheels",
            ComponentValue::Array(track.wheels.iter().map(|index| integer(*index)).collect()),
        ),
        ("inertia", number(track.inertia)),
        ("angularDamping", number(track.angular_damping)),
        ("maxBrakeTorque", number(track.max_brake_torque)),
        ("differentialRatio", number(track.differential_ratio)),
    ])
}

fn deserialize_track(
    document: Option<&BTreeMap<String, ComponentValue>>,
    fallback: VehicleTrackConfiguration,
) -> VehicleTrackConfiguration {
    let Some(document) = document else {
        return fallback;
    };
    VehicleTrackConfiguration::with_wheels(
        json_to_int(document.get("drivenWheel")).unwrap_or(fallback.driven_wheel),
        json_to_array(document.get("wheels"))
            .unwrap_or(&[])
            .iter()
            .filter_map(|value| json_to_int(Some(value)))
            .collect(),
        json_to_float(document.get("inertia")).unwrap_or(fallback.inertia),
        json_to_float(document.get("angularDamping")).unwrap_or(fallback.angular_damping),
        json_to_float(document.get("maxBrakeTorque")).unwrap_or(fallback.max_brake_torque),
        json_to_float(document.get("differentialRatio")).unwrap_or(fallback.differential_ratio),
    )
}

/// Swift `UInt8(clamping:)`.
fn clamping_u8(value: i64) -> u8 {
    value.clamp(0, i64::from(u8::MAX)) as u8
}

/// Swift `UInt16(clamping:)`.
fn clamping_u16(value: i64) -> u16 {
    value.clamp(0, i64::from(u16::MAX)) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rigid_body_defaults_match_the_swift_codec() {
        let body = BuiltinComponentCodecs::deserialize_rigid_body(&BTreeMap::new());
        assert_eq!(body.mass, 1.0);
        assert_eq!(body.linear_damping, 0.04);
        assert_eq!(body.angular_damping, 0.04);
        assert_eq!(body.max_linear_velocity, 500.0);
        assert_eq!(
            body.max_angular_velocity,
            0.25 * std::f32::consts::PI * 60.0
        );
        assert_eq!(body.motion_type, RigidBodyMotionType::Dynamic);
    }

    #[test]
    fn collider_falls_back_to_a_unit_box_and_clamps_layers() {
        let mut document = BTreeMap::new();
        document.insert("layerID".to_string(), integer(-4));
        document.insert("layerMask".to_string(), integer(70_000));
        let collider = BuiltinComponentCodecs::deserialize_collider(&document);
        assert_eq!(collider.layer_id, 0);
        assert_eq!(collider.layer_mask, u16::MAX);
        assert_eq!(
            collider.shape(),
            ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            }
        );
        assert_eq!(collider.material.restitution, 0.0);
    }

    #[test]
    fn collider_shape_instances_keep_local_transforms() {
        let mut instance = BTreeMap::new();
        instance.insert(
            "shape".to_string(),
            ComponentValue::String("sphere".to_string()),
        );
        instance.insert("radius".to_string(), number(2.0));
        instance.insert("localScale".to_string(), vec3_to_json(Float3::splat(3.0)));
        let mut document = BTreeMap::new();
        document.insert(
            "shapes".to_string(),
            ComponentValue::Array(vec![ComponentValue::Object(instance)]),
        );
        let collider = BuiltinComponentCodecs::deserialize_collider(&document);
        assert_eq!(collider.shapes.len(), 1);
        assert_eq!(collider.shapes[0].local_scale, Float3::splat(3.0));
        assert_eq!(
            collider.shape(),
            ColliderShape::Sphere {
                radius: 2.0,
                center: Float3::ZERO,
            }
        );
    }

    #[test]
    fn vehicle_round_trips_the_wheeled_default() {
        let vehicle = Vehicle::wheeled();
        let document = BuiltinComponentCodecs::serialize_vehicle(&vehicle);
        assert_eq!(
            BuiltinComponentCodecs::deserialize_vehicle(&document),
            vehicle
        );
    }

    #[test]
    fn tracked_vehicle_uses_the_tracked_fallback() {
        let vehicle = Vehicle::tracked_default();
        let document = BuiltinComponentCodecs::serialize_vehicle(&vehicle);
        let decoded = BuiltinComponentCodecs::deserialize_vehicle(&document);
        assert_eq!(decoded, vehicle);
    }

    #[test]
    fn cloth_defaults_to_distance_and_soft_body_mesh_to_dihedral() {
        let cloth = BuiltinComponentCodecs::deserialize_cloth(&BTreeMap::new());
        assert_eq!(cloth.bend_type, ClothBendType::Distance);
        assert_eq!(cloth.grid_size_x, 16);
        let mesh = BuiltinComponentCodecs::deserialize_soft_body_mesh(&BTreeMap::new());
        assert_eq!(mesh.bend_type, ClothBendType::Dihedral);
        assert_eq!(mesh.volume_compliance, 1.0e-6);
    }

    #[test]
    fn destructible_defaults_match_the_swift_codec() {
        let value = BuiltinComponentCodecs::deserialize_destructible(&BTreeMap::new());
        assert_eq!(value.damage_threshold, 100.0);
        assert_eq!(value.fragment_budget, 256);
        assert_eq!(value.separation_impulse, 0.05);
        assert!(value.is_enabled);
    }
}
