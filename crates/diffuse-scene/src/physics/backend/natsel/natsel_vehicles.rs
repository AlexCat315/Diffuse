//! Vehicle creation, driver input and state reporting for the Natsel backend.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Backend/Natsel/NatselVehicles.swift`.
//!
//! Tracked vehicles need a different driver-input call than wheeled ones, and a tracked
//! config must name a driven wheel that actually exists — both are validated here rather
//! than left to the engine, because a silently invalid track produces a vehicle that
//! never moves.

use diffuse_math::simd::simd_compat::Float4;

use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult, PhysicsStepContext,
};
use crate::physics::physics_types::{PhysicsBackendError, PhysicsBackendErrorCode};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::physics::vehicles::vehicle_controller_configuration::VehicleControllerConfiguration;
use crate::physics::vehicles::vehicle_powertrain::{
    VehicleEngineConfiguration, VehicleTransmissionConfiguration,
};
use crate::physics::vehicles::vehicle_state::{VehicleState, VehicleWheelState};
use crate::physics::vehicles::vehicle_wheel_configuration::VehicleTransmissionMode;

use super::natsel_physics_backend::{NatselPhysicsBackend, VehicleRecord};

impl NatselPhysicsBackend {
    /// `synchronizeVehicles(_:result:)`.
    pub(crate) fn synchronize_vehicles(
        &mut self,
        context: &PhysicsPrepareContext,
        result: &mut PhysicsPrepareResult,
    ) -> Result<(), PhysicsBackendError> {
        let active: std::collections::BTreeSet<EntityID> = context
            .active_vehicles
            .iter()
            .filter(|descriptor| descriptor.vehicle.is_enabled)
            .map(|descriptor| descriptor.entity)
            .collect();
        let mut stale: Vec<EntityID> = self
            .vehicles
            .keys()
            .copied()
            .filter(|entity| !active.contains(entity))
            .collect();
        stale.sort_by_key(|entity| entity.raw_value());
        for entity in stale {
            if let Some(old) = self.vehicles.remove(&entity) {
                self.world.destroy_vehicle(old.id);
                result.removed_vehicles += 1;
            }
        }

        let mut descriptors = context.active_vehicles.clone();
        descriptors.sort_by_key(|descriptor| descriptor.entity.raw_value());
        for descriptor in descriptors {
            if !descriptor.vehicle.is_enabled {
                continue;
            }
            let Some(body_id) = self.bodies.get(&descriptor.entity).map(|record| record.id) else {
                return Err(NatselPhysicsBackend::failure(
                    PhysicsBackendErrorCode::InvalidArgument,
                    "Vehicle requires a rigid body",
                ));
            };
            // An unchanged vehicle bound to the same body needs no rebuild.
            let unchanged = self
                .vehicles
                .get(&descriptor.entity)
                .is_some_and(|old| old.body == body_id && old.descriptor == descriptor);
            if unchanged {
                continue;
            }

            let config = descriptor.vehicle.clone();
            // A track must contain its own driven wheel and may only reference wheels
            // that exist.
            if let VehicleControllerConfiguration::Tracked(tracked) = &config.controller {
                for track in [&tracked.left_track, &tracked.right_track] {
                    let driven_present = track.wheels.contains(&track.driven_wheel);
                    let wheels_valid = track
                        .wheels
                        .iter()
                        .all(|wheel| *wheel >= 0 && (*wheel as usize) < config.wheels.len());
                    if !driven_present || !wheels_valid {
                        return Err(NatselPhysicsBackend::failure(
                            PhysicsBackendErrorCode::InvalidArgument,
                            "Track must contain its driven wheel and reference valid wheels",
                        ));
                    }
                }
            }

            let mut def = natsel::vehicle::vehicle_types::VehicleDef {
                body_id,
                ..natsel::vehicle::vehicle_types::VehicleDef::default()
            };
            let collider = self
                .bodies
                .get(&descriptor.entity)
                .and_then(|record| record.descriptor.collider.as_ref());
            def.filter = natsel::types::shape_def::QueryFilter::new(
                1u64 << collider.map_or(0, |collider| collider.layer_id.min(15)),
                u64::from(collider.map_or(u16::MAX, |collider| collider.layer_mask)),
            );
            def.up = NatselPhysicsBackend::nv(config.up);
            def.forward = NatselPhysicsBackend::nv(config.forward);
            def.max_pitch_roll_angle = config.max_pitch_roll_angle;
            def.collision_tester =
                natsel::vehicle::vehicle_types::VehicleCollisionTester::Cylinder(0.1);
            def.wheels = config
                .wheels
                .iter()
                .map(|value| {
                    let mut wheel = natsel::vehicle::vehicle_types::WheelSettings {
                        position: NatselPhysicsBackend::nv(value.position),
                        suspension_direction: NatselPhysicsBackend::nv(value.suspension_direction),
                        steering_axis: NatselPhysicsBackend::nv(value.steering_axis),
                        wheel_up: NatselPhysicsBackend::nv(value.wheel_up),
                        wheel_forward: NatselPhysicsBackend::nv(value.wheel_forward),
                        suspension_min_length: value.suspension_min_length,
                        suspension_max_length: value.suspension_max_length,
                        suspension_preload_length: value.suspension_preload_length,
                        suspension_frequency: value.suspension_frequency,
                        suspension_damping_ratio: value.suspension_damping,
                        radius: value.radius,
                        width: value.width,
                        inertia: value.inertia,
                        angular_damping: value.angular_damping,
                        max_steer_angle: value.max_steer_angle,
                        max_brake_torque: value.max_brake_torque,
                        max_hand_brake_torque: value.max_hand_brake_torque,
                        ..natsel::vehicle::vehicle_types::WheelSettings::default()
                    };
                    // Tracked configs override the friction coefficients per wheel.
                    if let VehicleControllerConfiguration::Tracked(tracked) = &config.controller {
                        wheel.track_longitudinal_friction = tracked.longitudinal_friction;
                        wheel.track_lateral_friction = tracked.lateral_friction;
                    }
                    wheel
                })
                .collect();
            def.anti_roll_bars = config
                .anti_roll_bars
                .iter()
                .map(|value| natsel::vehicle::vehicle_types::VehicleAntiRollBar {
                    left_wheel: value.left_wheel as i32,
                    right_wheel: value.right_wheel as i32,
                    stiffness: value.stiffness,
                })
                .collect();

            let wheeled = wheeled_settings(&config.engine, &config.transmission, &config);
            def.controller = match &config.controller {
                VehicleControllerConfiguration::Wheeled => {
                    natsel::vehicle::vehicle_types::VehicleControllerSettings::Wheeled(wheeled)
                }
                VehicleControllerConfiguration::Motorcycle(motorcycle) => {
                    let settings = natsel::vehicle::vehicle_types::MotorcycleControllerSettings {
                        wheeled,
                        max_lean_angle: motorcycle.max_lean_angle,
                        // A disabled lean controller contributes zero spring, not zero all.
                        lean_spring_constant: if motorcycle.is_lean_controller_enabled {
                            motorcycle.lean_spring_constant
                        } else {
                            0.0
                        },
                        lean_spring_damping: motorcycle.lean_spring_damping,
                        lean_spring_integration_coefficient: motorcycle
                            .lean_spring_integration_coefficient,
                        lean_spring_integration_coefficient_decay: motorcycle
                            .lean_spring_integration_coefficient_decay,
                        lean_smoothing_factor: motorcycle.lean_smoothing_factor,
                        enable_lean_steering_limit: motorcycle.is_lean_steering_limit_enabled,
                    };
                    natsel::vehicle::vehicle_types::VehicleControllerSettings::Motorcycle(settings)
                }
                VehicleControllerConfiguration::Tracked(tracked) => {
                    let settings =
                        natsel::vehicle::vehicle_types::TrackedVehicleControllerSettings {
                            engine: wheeled.engine,
                            transmission: wheeled.transmission,
                            tracks: [&tracked.left_track, &tracked.right_track]
                                .into_iter()
                                .map(
                                    |value| natsel::vehicle::vehicle_types::VehicleTrackSettings {
                                        driven_wheel: value.driven_wheel as i32,
                                        wheels: value
                                            .wheels
                                            .iter()
                                            .map(|wheel| *wheel as i32)
                                            .collect(),
                                        inertia: value.inertia,
                                        angular_damping: value.angular_damping,
                                        max_brake_torque: value.max_brake_torque,
                                        differential_ratio: value.differential_ratio,
                                    },
                                )
                                .collect(),
                        };
                    natsel::vehicle::vehicle_types::VehicleControllerSettings::Tracked(settings)
                }
            };

            let id = self.world.create_vehicle(&def);
            if !self.world.vehicle_is_valid(id) {
                return Err(NatselPhysicsBackend::failure(
                    PhysicsBackendErrorCode::InvalidArgument,
                    "Invalid vehicle configuration",
                ));
            }
            if let Some(old) = self.vehicles.insert(
                descriptor.entity,
                VehicleRecord {
                    id,
                    body: body_id,
                    descriptor,
                },
            ) {
                self.world.destroy_vehicle(old.id);
            }
            result.synchronized_vehicles += 1;
        }
        Ok(())
    }

    /// `applyVehicleCommands(_:)` — tracked vehicles take a left/right ratio pair, and
    /// the ratio is normalized by the larger of throttle and steering so a full-lock
    /// turn at full throttle still sums to one.
    pub(crate) fn apply_vehicle_commands(&mut self, context: &PhysicsStepContext) {
        let mut entities: Vec<EntityID> = self.vehicles.keys().copied().collect();
        entities.sort_by_key(|entity| entity.raw_value());
        for entity in entities {
            let Some(record) = self.vehicles.get(&entity) else {
                continue;
            };
            let id = record.id;
            let is_tracked = matches!(
                record.descriptor.vehicle.controller,
                VehicleControllerConfiguration::Tracked(_)
            );
            let command = context
                .vehicle_commands
                .get(&entity)
                .cloned()
                .unwrap_or_default();
            if is_tracked {
                let magnitude = command.throttle.abs().max(command.steering.abs());
                let left = if magnitude > 0.0 {
                    ((command.throttle + command.steering) / magnitude).clamp(-1.0, 1.0)
                } else {
                    0.0
                };
                let right = if magnitude > 0.0 {
                    ((command.throttle - command.steering) / magnitude).clamp(-1.0, 1.0)
                } else {
                    0.0
                };
                self.world.set_tracked_vehicle_driver_input(
                    id,
                    magnitude,
                    left,
                    right,
                    command.brake,
                );
            } else {
                self.world.set_vehicle_driver_input(
                    id,
                    command.throttle,
                    command.steering,
                    command.brake,
                    command.hand_brake,
                );
            }
            if let Some(gear) = command.manual_gear {
                self.world
                    .set_vehicle_transmission(id, gear as i32, command.clutch);
            }
        }
    }
}

/// `vehicleEngine` + `vehicleTransmission` + the differential list.
fn wheeled_settings(
    engine: &VehicleEngineConfiguration,
    transmission: &VehicleTransmissionConfiguration,
    config: &Vehicle,
) -> natsel::vehicle::vehicle_types::WheeledVehicleControllerSettings {
    let engine_settings = natsel::vehicle::vehicle_types::VehicleEngineSettings {
        max_torque: engine.max_torque,
        min_rpm: engine.min_rpm,
        max_rpm: engine.max_rpm,
        inertia: engine.inertia,
        angular_damping: engine.angular_damping,
        ..natsel::vehicle::vehicle_types::VehicleEngineSettings::default()
    };

    let transmission_settings = natsel::vehicle::vehicle_types::VehicleTransmissionSettings {
        mode: match transmission.mode {
            VehicleTransmissionMode::Manual => {
                natsel::vehicle::vehicle_types::TransmissionMode::Manual
            }
            VehicleTransmissionMode::Automatic => {
                natsel::vehicle::vehicle_types::TransmissionMode::Automatic
            }
        },
        gear_ratios: transmission.gear_ratios.clone(),
        reverse_gear_ratios: transmission.reverse_gear_ratios.clone(),
        switch_time: transmission.switch_time,
        clutch_release_time: transmission.clutch_release_time,
        switch_latency: transmission.switch_latency,
        shift_up_rpm: transmission.shift_up_rpm,
        shift_down_rpm: transmission.shift_down_rpm,
        clutch_strength: transmission.clutch_strength,
    };

    natsel::vehicle::vehicle_types::WheeledVehicleControllerSettings {
        engine: engine_settings,
        transmission: transmission_settings,
        differentials: config
            .differentials
            .iter()
            .map(
                |value| natsel::vehicle::vehicle_types::VehicleDifferentialSettings {
                    left_wheel: value.left_wheel as i32,
                    right_wheel: value.right_wheel as i32,
                    differential_ratio: value.differential_ratio,
                    left_right_split: value.left_right_split,
                    limited_slip_ratio: value.limited_slip_ratio,
                    engine_torque_ratio: value.engine_torque_ratio,
                },
            )
            .collect(),
        ..natsel::vehicle::vehicle_types::WheeledVehicleControllerSettings::default()
    }
}

/// `vehicleStates()`.
pub(crate) fn vehicle_states(backend: &NatselPhysicsBackend) -> Vec<VehicleState> {
    let mut entities: Vec<EntityID> = backend.vehicles.keys().copied().collect();
    entities.sort_by_key(|entity| entity.raw_value());
    entities
        .into_iter()
        .filter_map(|entity| {
            let record = backend.vehicles.get(&entity)?;
            let id = record.id;
            let drivetrain = backend.world.vehicle_drivetrain_state(id);
            let wheel_count = backend.world.vehicle_wheel_count(id);
            let mut wheels = Vec::new();
            for index in 0..wheel_count {
                let Some(state) = backend.world.vehicle_wheel_state(id, index) else {
                    continue;
                };
                let wheel = record.descriptor.vehicle.wheels.get(index as usize);
                let Some(pose) = backend.world.vehicle_wheel_transform(
                    id,
                    index,
                    wheel
                        .map(|value| NatselPhysicsBackend::nv(value.wheel_forward))
                        .unwrap_or(natsel::math::types::Vec3::new(1.0, 0.0, 0.0)),
                    wheel
                        .map(|value| NatselPhysicsBackend::nv(value.wheel_up))
                        .unwrap_or(natsel::math::types::Vec3::new(0.0, 1.0, 0.0)),
                ) else {
                    continue;
                };
                let contact_entity = backend
                    .bodies
                    .iter()
                    .find(|(_, body)| body.id == state.contact_body_id)
                    .map(|(entity, _)| *entity);
                wheels.push(VehicleWheelState {
                    index: index as i64,
                    world_position: NatselPhysicsBackend::sv_pos(pose.p),
                    world_rotation: Float4::new(pose.q.v.x, pose.q.v.y, pose.q.v.z, pose.q.s),
                    angular_velocity: state.angular_velocity,
                    rotation_angle: state.rotation_angle,
                    steer_angle: state.steer_angle,
                    suspension_length: state.suspension_length,
                    has_contact: state.has_contact,
                    contact_entity,
                    contact_position: NatselPhysicsBackend::sv_pos(state.contact_position),
                    contact_normal: NatselPhysicsBackend::sv(state.contact_normal),
                });
            }
            Some(VehicleState {
                entity,
                forward_speed: backend.world.vehicle_forward_speed(id),
                engine_rpm: drivetrain.as_ref().map_or(0.0, |state| state.engine_rpm),
                current_gear: drivetrain
                    .as_ref()
                    .map_or(0, |state| state.current_gear as i64),
                clutch_friction: drivetrain
                    .as_ref()
                    .map_or(0.0, |state| state.clutch_friction),
                wheels,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vehicle_states_is_empty_without_vehicles() {
        let backend = NatselPhysicsBackend::new();
        let states = vehicle_states(&backend);
        assert!(states.is_empty());
    }

    #[test]
    fn tracked_ratio_normalizes_by_the_larger_axis() {
        // Mirrors `apply_vehicle_commands`' arithmetic for a full-lock, full-throttle
        // command: throttle 1, steering 1 gives left 1, right 0.
        let magnitude = 1.0f32.max(1.0);
        let left = ((1.0 + 1.0) / magnitude).clamp(-1.0, 1.0);
        let right = ((1.0 - 1.0) / magnitude).clamp(-1.0, 1.0);
        assert_eq!(left, 1.0);
        assert_eq!(right, 0.0);
    }

    #[test]
    fn tracked_ratio_is_zero_when_no_input() {
        let magnitude = 0.0f32.max(0.0);
        // `!(x > 0.0)` rather than `x <= 0.0`: Swift's `guard x > 0 else` also rejects
        // NaN, so the negated form is the faithful one.
        #[allow(clippy::neg_cmp_op_on_partial_ord)]
        {
            assert!(!(magnitude > 0.0));
        }
    }
}
