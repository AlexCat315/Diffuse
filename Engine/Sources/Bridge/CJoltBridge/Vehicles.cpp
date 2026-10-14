#include "Internal.hpp"

using namespace jolt;

// Wheeled, tracked and motorcycle vehicles.


bool GuavaJoltContextImpl::destroy_vehicle(uint64_t entity) {
    auto existing = vehicles.find(entity);
    if (existing == vehicles.end()) return false;
    if (existing->second.constraint) {
        physics_system.RemoveStepListener(existing->second.constraint);
        physics_system.RemoveConstraint(existing->second.constraint);
    }
    vehicles.erase(existing);
    return true;
    }

bool GuavaJoltContextImpl::sync_vehicles( const GuavaJoltVehicleDesc* upserts, size_t upsert_count, const uint64_t* removals, size_t removal_count, bool full_snapshot, GuavaJoltVehicleSyncStats* out_stats) {
    last_error = GUAVA_JOLT_ERROR_NONE;
    if (!out_stats
        || (upsert_count > 0 && !upserts)
        || (removal_count > 0 && !removals)) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }

    std::unordered_set<uint64_t> incoming;
    incoming.reserve(upsert_count);
    for (size_t i = 0; i < upsert_count; ++i) {
        incoming.insert(upserts[i].entity_id);
    }

    std::vector<uint64_t> stale;
    if (full_snapshot) {
        for (const auto& entry : vehicles) {
            if (incoming.find(entry.first) == incoming.end()) stale.push_back(entry.first);
        }
    }
    if (removal_count > 0) stale.insert(stale.end(), removals, removals + removal_count);
    for (size_t i = 0; i < upsert_count; ++i) {
        if (!upserts[i].is_enabled) stale.push_back(upserts[i].entity_id);
    }
    std::sort(stale.begin(), stale.end());
    stale.erase(std::unique(stale.begin(), stale.end()), stale.end());
    uint32_t removed_count = 0;
    for (uint64_t entity : stale) {
        if (destroy_vehicle(entity)) ++removed_count;
    }

    std::vector<const GuavaJoltVehicleDesc*> ordered;
    ordered.reserve(upsert_count);
    for (size_t i = 0; i < upsert_count; ++i) ordered.push_back(&upserts[i]);
    std::sort(ordered.begin(), ordered.end(), [](const auto* lhs, const auto* rhs) {
        return lhs->entity_id < rhs->entity_id;
    });

    uint32_t synchronized_count = 0;
    for (const GuavaJoltVehicleDesc* desc_ptr : ordered) {
        const GuavaJoltVehicleDesc& desc = *desc_ptr;
        if (!desc.is_enabled) continue;
        if (desc.wheel_count < 2 || !desc.wheels
            || desc.controller_type > 2
            || (desc.differential_count > 0 && !desc.differentials)
            || (desc.anti_roll_bar_count > 0 && !desc.anti_roll_bars)
            || (desc.track_count > 0 && !desc.tracks)
            || desc.gear_ratio_count == 0 || !desc.gear_ratios
            || desc.reverse_gear_ratio_count == 0 || !desc.reverse_gear_ratios) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
        if ((desc.controller_type == 1 && desc.track_count != 2)
            || (desc.controller_type != 1 && desc.track_count != 0)
            || (desc.controller_type == 2 && desc.wheel_count != 2)) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
        auto body_it = bodies.ids.find(desc.entity_id);
        if (body_it == bodies.ids.end()
            || physics_system.GetBodyInterface().GetMotionType(body_it->second) != JPH::EMotionType::Dynamic) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
        for (uint32_t i = 0; i < desc.differential_count; ++i) {
            const auto& differential = desc.differentials[i];
            const bool left_valid = differential.left_wheel >= -1
                && differential.left_wheel < static_cast<int32_t>(desc.wheel_count);
            const bool right_valid = differential.right_wheel >= -1
                && differential.right_wheel < static_cast<int32_t>(desc.wheel_count);
            if (!left_valid || !right_valid
                || (differential.left_wheel < 0 && differential.right_wheel < 0)) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
        }
        for (uint32_t i = 0; i < desc.anti_roll_bar_count; ++i) {
            const auto& bar = desc.anti_roll_bars[i];
            if (bar.left_wheel < 0 || bar.right_wheel < 0
                || bar.left_wheel >= static_cast<int32_t>(desc.wheel_count)
                || bar.right_wheel >= static_cast<int32_t>(desc.wheel_count)) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
        }
        for (uint32_t i = 0; i < desc.track_count; ++i) {
            const auto& track = desc.tracks[i];
            if (track.wheel_count == 0 || !track.wheels
                || track.driven_wheel < 0
                || track.driven_wheel >= static_cast<int32_t>(desc.wheel_count)) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
            bool includes_driven_wheel = false;
            for (uint32_t j = 0; j < track.wheel_count; ++j) {
                const int32_t wheel = track.wheels[j];
                if (wheel < 0 || wheel >= static_cast<int32_t>(desc.wheel_count)) {
                    last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                    return false;
                }
                includes_driven_wheel |= wheel == track.driven_wheel;
            }
            if (!includes_driven_wheel) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
        }

        if (destroy_vehicle(desc.entity_id)) ++removed_count;

        JPH::VehicleConstraintSettings settings;
        settings.mUp = safe_normalized(
            JPH::Vec3(desc.up_x, desc.up_y, desc.up_z), JPH::Vec3::sAxisY());
        settings.mForward = safe_normalized(
            JPH::Vec3(desc.forward_x, desc.forward_y, desc.forward_z), JPH::Vec3::sAxisZ());
        settings.mMaxPitchRollAngle = JPH::Clamp(
            desc.max_pitch_roll_angle, 0.0f, JPH::JPH_PI);
        settings.mWheels.reserve(desc.wheel_count);
        for (uint32_t i = 0; i < desc.wheel_count; ++i) {
            const GuavaJoltVehicleWheelDesc& source = desc.wheels[i];
            JPH::WheelSettings* wheel = nullptr;
            if (desc.controller_type == 1) {
                auto* tracked_wheel = new JPH::WheelSettingsTV;
                tracked_wheel->mLongitudinalFriction = std::max(
                    0.0f, desc.tracked_longitudinal_friction);
                tracked_wheel->mLateralFriction = std::max(
                    0.0f, desc.tracked_lateral_friction);
                wheel = tracked_wheel;
            } else {
                auto* wheeled_wheel = new JPH::WheelSettingsWV;
                wheeled_wheel->mInertia = std::max(0.001f, source.inertia);
                wheeled_wheel->mAngularDamping = std::max(0.0f, source.angular_damping);
                wheeled_wheel->mMaxSteerAngle = std::max(0.0f, source.max_steer_angle);
                wheeled_wheel->mMaxBrakeTorque = std::max(0.0f, source.max_brake_torque);
                wheeled_wheel->mMaxHandBrakeTorque = std::max(
                    0.0f, source.max_hand_brake_torque);
                wheel = wheeled_wheel;
            }
            wheel->mPosition = JPH::Vec3(source.position_x, source.position_y, source.position_z);
            wheel->mSuspensionDirection = safe_normalized(
                JPH::Vec3(source.suspension_direction_x, source.suspension_direction_y,
                          source.suspension_direction_z), -settings.mUp);
            wheel->mSteeringAxis = safe_normalized(
                JPH::Vec3(source.steering_axis_x, source.steering_axis_y, source.steering_axis_z),
                settings.mUp);
            wheel->mWheelUp = safe_normalized(
                JPH::Vec3(source.wheel_up_x, source.wheel_up_y, source.wheel_up_z), settings.mUp);
            wheel->mWheelForward = safe_normalized(
                JPH::Vec3(source.wheel_forward_x, source.wheel_forward_y, source.wheel_forward_z),
                settings.mForward);
            wheel->mSuspensionMinLength = std::max(0.0f, source.suspension_min_length);
            wheel->mSuspensionMaxLength = std::max(
                wheel->mSuspensionMinLength, source.suspension_max_length);
            wheel->mSuspensionPreloadLength = std::max(0.0f, source.suspension_preload_length);
            wheel->mSuspensionSpring = JPH::SpringSettings(
                JPH::ESpringMode::FrequencyAndDamping,
                std::max(0.0f, source.suspension_frequency),
                std::max(0.0f, source.suspension_damping));
            wheel->mRadius = std::max(0.01f, source.radius);
            wheel->mWidth = std::max(0.01f, source.width);
            settings.mWheels.push_back(wheel);
        }

        auto configure_powertrain = [&](auto* controller) {
            controller->mEngine.mMaxTorque = std::max(0.0f, desc.engine_max_torque);
            controller->mEngine.mMinRPM = std::max(0.0f, desc.engine_min_rpm);
            controller->mEngine.mMaxRPM = std::max(
                controller->mEngine.mMinRPM, desc.engine_max_rpm);
            controller->mEngine.mInertia = std::max(0.001f, desc.engine_inertia);
            controller->mEngine.mAngularDamping = std::max(
                0.0f, desc.engine_angular_damping);
            auto& transmission = controller->mTransmission;
            transmission.mMode = desc.transmission_mode == 1
                ? JPH::ETransmissionMode::Manual
                : JPH::ETransmissionMode::Auto;
            transmission.mGearRatios.clear();
            for (uint32_t i = 0; i < desc.gear_ratio_count; ++i) {
                transmission.mGearRatios.push_back(desc.gear_ratios[i]);
            }
            transmission.mReverseGearRatios.clear();
            for (uint32_t i = 0; i < desc.reverse_gear_ratio_count; ++i) {
                transmission.mReverseGearRatios.push_back(desc.reverse_gear_ratios[i]);
            }
            transmission.mSwitchTime = std::max(0.0f, desc.transmission_switch_time);
            transmission.mClutchReleaseTime = std::max(
                0.0f, desc.transmission_clutch_release_time);
            transmission.mSwitchLatency = std::max(
                0.0f, desc.transmission_switch_latency);
            transmission.mShiftUpRPM = std::max(0.0f, desc.transmission_shift_up_rpm);
            transmission.mShiftDownRPM = JPH::Clamp(
                desc.transmission_shift_down_rpm, 0.0f, transmission.mShiftUpRPM);
            transmission.mClutchStrength = std::max(
                0.0f, desc.transmission_clutch_strength);
        };
        auto configure_differentials = [&](auto* controller) {
            controller->mDifferentials.clear();
            for (uint32_t i = 0; i < desc.differential_count; ++i) {
                const GuavaJoltVehicleDifferentialDesc& source = desc.differentials[i];
                JPH::VehicleDifferentialSettings differential;
                differential.mLeftWheel = source.left_wheel;
                differential.mRightWheel = source.right_wheel;
                differential.mDifferentialRatio = std::max(
                    0.001f, source.differential_ratio);
                differential.mLeftRightSplit = JPH::Clamp(
                    source.left_right_split, 0.0f, 1.0f);
                differential.mLimitedSlipRatio = std::max(
                    1.0001f, source.limited_slip_ratio);
                differential.mEngineTorqueRatio = std::max(
                    0.0f, source.engine_torque_ratio);
                controller->mDifferentials.push_back(differential);
            }
        };
        if (desc.controller_type == 1) {
            JPH::Ref<JPH::TrackedVehicleControllerSettings> controller =
                new JPH::TrackedVehicleControllerSettings;
            configure_powertrain(controller.GetPtr());
            for (uint32_t track_index = 0; track_index < 2; ++track_index) {
                const GuavaJoltVehicleTrackDesc& source = desc.tracks[track_index];
                JPH::VehicleTrackSettings& track = controller->mTracks[track_index];
                track.mDrivenWheel = static_cast<JPH::uint>(source.driven_wheel);
                track.mWheels.clear();
                for (uint32_t i = 0; i < source.wheel_count; ++i) {
                    track.mWheels.push_back(static_cast<JPH::uint>(source.wheels[i]));
                }
                track.mInertia = std::max(0.001f, source.inertia);
                track.mAngularDamping = std::max(0.0f, source.angular_damping);
                track.mMaxBrakeTorque = std::max(0.0f, source.max_brake_torque);
                track.mDifferentialRatio = std::max(0.001f, source.differential_ratio);
            }
            settings.mController = controller;
        } else if (desc.controller_type == 2) {
            JPH::Ref<JPH::MotorcycleControllerSettings> controller =
                new JPH::MotorcycleControllerSettings;
            configure_powertrain(controller.GetPtr());
            configure_differentials(controller.GetPtr());
            controller->mMaxLeanAngle = JPH::Clamp(
                desc.motorcycle_max_lean_angle, 0.0f, 0.5f * JPH::JPH_PI);
            controller->mLeanSpringConstant = std::max(
                0.0f, desc.motorcycle_lean_spring_constant);
            controller->mLeanSpringDamping = std::max(
                0.0f, desc.motorcycle_lean_spring_damping);
            controller->mLeanSpringIntegrationCoefficient = std::max(
                0.0f, desc.motorcycle_lean_spring_integration_coefficient);
            controller->mLeanSpringIntegrationCoefficientDecay = std::max(
                0.0f, desc.motorcycle_lean_spring_integration_coefficient_decay);
            controller->mLeanSmoothingFactor = JPH::Clamp(
                desc.motorcycle_lean_smoothing_factor, 0.0f, 1.0f);
            settings.mController = controller;
        } else {
            JPH::Ref<JPH::WheeledVehicleControllerSettings> controller =
                new JPH::WheeledVehicleControllerSettings;
            configure_powertrain(controller.GetPtr());
            configure_differentials(controller.GetPtr());
            settings.mController = controller;
        }
        settings.mAntiRollBars.clear();
        for (uint32_t i = 0; i < desc.anti_roll_bar_count; ++i) {
            const GuavaJoltVehicleAntiRollBarDesc& source = desc.anti_roll_bars[i];
            JPH::VehicleAntiRollBar bar;
            bar.mLeftWheel = source.left_wheel;
            bar.mRightWheel = source.right_wheel;
            bar.mStiffness = std::max(0.0f, source.stiffness);
            settings.mAntiRollBars.push_back(bar);
        }

        JPH::Ref<JPH::VehicleConstraint> vehicle_constraint;
        {
            JPH::BodyLockWrite lock(physics_system.GetBodyLockInterface(), body_it->second);
            if (!lock.Succeeded()) {
                last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
                return false;
            }
            vehicle_constraint = new JPH::VehicleConstraint(lock.GetBody(), settings);
        }
        if (desc.controller_type == 2) {
            vehicle_constraint->SetVehicleCollisionTester(
                new JPH::VehicleCollisionTesterCastCylinder(Layers::MOVING, 1.0f));
            auto* motorcycle = static_cast<JPH::MotorcycleController*>(
                vehicle_constraint->GetController());
            motorcycle->EnableLeanController(
                desc.motorcycle_enable_lean_controller != 0);
            motorcycle->EnableLeanSteeringLimit(
                desc.motorcycle_enable_lean_steering_limit != 0);
        } else {
            vehicle_constraint->SetVehicleCollisionTester(
                new JPH::VehicleCollisionTesterRay(Layers::MOVING));
        }
        physics_system.AddConstraint(vehicle_constraint);
        physics_system.AddStepListener(vehicle_constraint);
        vehicles[desc.entity_id] = NativeVehicle{
            vehicle_constraint,
            desc.wheel_count,
            desc.gear_ratio_count,
            desc.reverse_gear_ratio_count,
            desc.transmission_mode == 1,
            desc.controller_type
        };
        physics_system.GetBodyInterface().ActivateBody(body_it->second);
        ++synchronized_count;
    }

    out_stats->synchronized_vehicles = synchronized_count;
    out_stats->removed_vehicles = removed_count;
    return true;
    }

bool GuavaJoltContextImpl::set_vehicle_commands(const GuavaJoltVehicleCommand* commands, size_t command_count) {
    last_error = GUAVA_JOLT_ERROR_NONE;
    if (command_count > 0 && !commands) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }
    for (size_t i = 0; i < command_count; ++i) {
        const GuavaJoltVehicleCommand& command = commands[i];
        auto vehicle_it = vehicles.find(command.entity_id);
        if (vehicle_it == vehicles.end() || !command.has_manual_gear) continue;
        const NativeVehicle& vehicle = vehicle_it->second;
        if (!vehicle.uses_manual_transmission
            || command.manual_gear < -static_cast<int32_t>(vehicle.reverse_gear_count)
            || command.manual_gear > static_cast<int32_t>(vehicle.forward_gear_count)) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
    }
    std::vector<uint64_t> ids;
    ids.reserve(vehicles.size());
    for (const auto& entry : vehicles) ids.push_back(entry.first);
    std::sort(ids.begin(), ids.end());
    for (uint64_t entity : ids) {
        NativeVehicle& vehicle = vehicles[entity];
        if (vehicle.controller_type == 1) {
            auto* controller = static_cast<JPH::TrackedVehicleController*>(
                vehicle.constraint->GetController());
            controller->SetDriverInput(0, 1, 1, 0);
        } else {
            auto* controller = static_cast<JPH::WheeledVehicleController*>(
                vehicle.constraint->GetController());
            controller->SetDriverInput(0, 0, 0, 0);
        }
    }
    for (size_t i = 0; i < command_count; ++i) {
        const GuavaJoltVehicleCommand& command = commands[i];
        auto vehicle_it = vehicles.find(command.entity_id);
        if (vehicle_it == vehicles.end()) continue;
        NativeVehicle& vehicle = vehicle_it->second;
        if (vehicle.controller_type == 1) {
            auto* controller = static_cast<JPH::TrackedVehicleController*>(
                vehicle.constraint->GetController());
            float throttle = JPH::Clamp(command.throttle, -1.0f, 1.0f);
            const float steering = JPH::Clamp(command.steering, -1.0f, 1.0f);
            float left_ratio = 1.0f;
            float right_ratio = 1.0f;
            if (steering > 0.001f) {
                if (std::abs(throttle) < 0.001f) {
                    throttle = steering;
                    right_ratio = -1.0f;
                } else {
                    right_ratio = std::max(0.2f, 1.0f - 0.8f * steering);
                }
            } else if (steering < -0.001f) {
                if (std::abs(throttle) < 0.001f) {
                    throttle = -steering;
                    left_ratio = -1.0f;
                } else {
                    left_ratio = std::max(0.2f, 1.0f + 0.8f * steering);
                }
            }
            controller->SetDriverInput(
                throttle,
                left_ratio,
                right_ratio,
                std::max(JPH::Clamp(command.brake, 0.0f, 1.0f),
                         JPH::Clamp(command.hand_brake, 0.0f, 1.0f)));
            if (command.has_manual_gear) {
                controller->GetTransmission().Set(
                    command.manual_gear, JPH::Clamp(command.clutch, 0.0f, 1.0f));
            }
        } else {
            auto* controller = static_cast<JPH::WheeledVehicleController*>(
                vehicle.constraint->GetController());
            controller->SetDriverInput(
                JPH::Clamp(command.throttle, -1.0f, 1.0f),
                JPH::Clamp(command.steering, -1.0f, 1.0f),
                JPH::Clamp(command.brake, 0.0f, 1.0f),
                JPH::Clamp(command.hand_brake, 0.0f, 1.0f));
            if (command.has_manual_gear) {
                controller->GetTransmission().Set(
                    command.manual_gear, JPH::Clamp(command.clutch, 0.0f, 1.0f));
            }
        }
        if (command.throttle != 0 || command.steering != 0
            || command.brake != 0 || command.hand_brake != 0) {
            auto body_it = bodies.ids.find(command.entity_id);
            if (body_it != bodies.ids.end()) {
                physics_system.GetBodyInterface().ActivateBody(body_it->second);
            }
        }
    }
    return true;
    }

uint32_t GuavaJoltContextImpl::copy_vehicle_states( GuavaJoltVehicleState* out_states, size_t state_capacity, GuavaJoltVehicleWheelState* out_wheel_states, size_t wheel_state_capacity, uint32_t* out_wheel_state_count) const {
    if (!out_wheel_state_count
        || (state_capacity > 0 && !out_states)
        || (wheel_state_capacity > 0 && !out_wheel_states)) return 0;
    std::vector<uint64_t> ids;
    ids.reserve(vehicles.size());
    for (const auto& entry : vehicles) ids.push_back(entry.first);
    std::sort(ids.begin(), ids.end());
    size_t written_states = 0;
    size_t written_wheels = 0;
    const JPH::BodyInterface& body_interface = physics_system.GetBodyInterface();
    for (uint64_t entity : ids) {
        if (written_states >= state_capacity) break;
        const NativeVehicle& native = vehicles.at(entity);
        auto body_it = bodies.ids.find(entity);
        if (body_it == bodies.ids.end()) continue;
        const JPH::Quat body_rotation = body_interface.GetRotation(body_it->second);
        const JPH::Vec3 forward = body_rotation * native.constraint->GetLocalForward();
        GuavaJoltVehicleState& state = out_states[written_states++];
        state.entity_id = entity;
        state.forward_speed = body_interface.GetLinearVelocity(body_it->second).Dot(forward);
        if (native.controller_type == 1) {
            const auto* controller = static_cast<const JPH::TrackedVehicleController*>(
                native.constraint->GetController());
            state.engine_rpm = controller->GetEngine().GetCurrentRPM();
            state.current_gear = controller->GetTransmission().GetCurrentGear();
            state.clutch_friction = controller->GetTransmission().GetClutchFriction();
        } else {
            const auto* controller = static_cast<const JPH::WheeledVehicleController*>(
                native.constraint->GetController());
            state.engine_rpm = controller->GetEngine().GetCurrentRPM();
            state.current_gear = controller->GetTransmission().GetCurrentGear();
            state.clutch_friction = controller->GetTransmission().GetClutchFriction();
        }
        state.wheel_state_offset = static_cast<uint32_t>(written_wheels);
        const size_t remaining = wheel_state_capacity - written_wheels;
        state.wheel_state_count = static_cast<uint32_t>(
            std::min<size_t>(native.wheel_count, remaining));
        for (uint32_t wheel_index = 0; wheel_index < state.wheel_state_count; ++wheel_index) {
            const JPH::Wheel* wheel = native.constraint->GetWheel(wheel_index);
            const JPH::RMat44 transform = native.constraint->GetWheelWorldTransform(
                wheel_index, JPH::Vec3::sAxisX(), JPH::Vec3::sAxisY());
            const JPH::RVec3 position = transform.GetTranslation();
            const JPH::Quat rotation = transform.GetQuaternion();
            GuavaJoltVehicleWheelState& output = out_wheel_states[written_wheels++];
            output = GuavaJoltVehicleWheelState{};
            output.vehicle_entity_id = entity;
            output.wheel_index = wheel_index;
            output.world_position_x = static_cast<float>(position.GetX());
            output.world_position_y = static_cast<float>(position.GetY());
            output.world_position_z = static_cast<float>(position.GetZ());
            output.world_rotation_x = rotation.GetX();
            output.world_rotation_y = rotation.GetY();
            output.world_rotation_z = rotation.GetZ();
            output.world_rotation_w = rotation.GetW();
            output.angular_velocity = wheel->GetAngularVelocity();
            output.rotation_angle = wheel->GetRotationAngle();
            output.steer_angle = wheel->GetSteerAngle();
            output.suspension_length = wheel->GetSuspensionLength();
            output.has_contact = wheel->HasContact() ? 1 : 0;
            if (wheel->HasContact()) {
                uint64_t contact_entity = 0;
                output.has_contact_entity = entity_for_body_id(
                    wheel->GetContactBodyID(), contact_entity) ? 1 : 0;
                output.contact_entity_id = contact_entity;
                const JPH::RVec3 contact_position = wheel->GetContactPosition();
                const JPH::Vec3 contact_normal = wheel->GetContactNormal();
                output.contact_position_x = static_cast<float>(contact_position.GetX());
                output.contact_position_y = static_cast<float>(contact_position.GetY());
                output.contact_position_z = static_cast<float>(contact_position.GetZ());
                output.contact_normal_x = contact_normal.GetX();
                output.contact_normal_y = contact_normal.GetY();
                output.contact_normal_z = contact_normal.GetZ();
            }
        }
    }
    *out_wheel_state_count = static_cast<uint32_t>(written_wheels);
    return static_cast<uint32_t>(written_states);
    }

