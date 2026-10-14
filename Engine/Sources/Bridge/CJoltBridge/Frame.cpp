#include "Internal.hpp"

using namespace jolt;

// Frame reconciliation (prepare) and simulation (step).

bool GuavaJoltContextImpl::prepare(const GuavaJoltBodyDesc* body_descs, size_t body_count, const GuavaJoltConstraintDesc* constraints_in, size_t constraint_count, const GuavaJoltMeshGeometry* mesh_geometries, size_t mesh_count, const uint64_t* body_removals, size_t body_removal_count, const uint64_t* constraint_removals, size_t constraint_removal_count, bool incremental, GuavaJoltPrepareStats* out_stats) {
    last_error = GUAVA_JOLT_ERROR_NONE;
    // Begin the rendered-frame event window before synchronization. Body
    // insertion can immediately emit sensor/contact callbacks, and multiple
    // fixed substeps should accumulate into one PhysicsEventFrameResource.
    events.contact_listener.begin_step();
    events.joint_break_events.clear();
    if ((body_count > 0 && !body_descs)
        || (constraint_count > 0 && !constraints_in)
        || (mesh_count > 0 && !mesh_geometries)
        || (body_removal_count > 0 && !body_removals)
        || (constraint_removal_count > 0 && !constraint_removals)) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }

            // Cache mesh geometry by entity and explicit geometry revision. Swift only
    // sends changed revisions, so unchanged meshes avoid crossing and copying the
    // C ABI boundary on every rendered frame.
    if (mesh_geometries) {
        for (size_t i = 0; i < mesh_count; ++i) {
            const auto& m = mesh_geometries[i];
            auto revision = meshes.revisions.find(m.entity_id);
            if (revision != meshes.revisions.end()
                && revision->second == m.geometry_revision) {
                continue;
            }
            if (m.vertices && m.vertex_count > 0) {
                meshes.vertices[m.entity_id].assign(m.vertices, m.vertices + m.vertex_count * 3);
            } else {
                meshes.vertices.erase(m.entity_id);
            }
            if (m.indices && m.index_count > 0) {
                meshes.indices[m.entity_id].assign(m.indices, m.indices + m.index_count);
            } else {
                meshes.indices.erase(m.entity_id);
            }
            meshes.revisions[m.entity_id] = m.geometry_revision;
        }
    }
    
            JPH::BodyInterface& bi = physics_system.GetBodyInterface();

            // Stable joints survive prepare. Only dirty/deleted joints, or joints
    // attached to a body that must be recreated, are rebuilt below.
            uint32_t removed_constraints = 0;
    
            // Track which entities are present this frame.
            std::unordered_map<uint64_t, const GuavaJoltBodyDesc*> incoming;
            if (body_descs) {
                for (size_t i = 0; i < body_count; ++i) incoming[body_descs[i].entity_id] = &body_descs[i];
    }

    // Full snapshots remove everything absent from the incoming set. Incremental
    // synchronization removes only the stable, explicitly supplied entity IDs.
            uint32_t removed_bodies = 0;
    std::vector<uint64_t> bodies_to_remove;
    if (incremental) {
        if (body_removal_count > 0) {
            bodies_to_remove.assign(body_removals, body_removals + body_removal_count);
        }
    } else {
        for (const auto& entry : bodies.ids) {
            if (incoming.find(entry.first) == incoming.end()) {
                bodies_to_remove.push_back(entry.first);
            }
        }
    }
    std::sort(bodies_to_remove.begin(), bodies_to_remove.end());
    bodies_to_remove.erase(
        std::unique(bodies_to_remove.begin(), bodies_to_remove.end()),
        bodies_to_remove.end());
    for (uint64_t entity : bodies_to_remove) {
        auto existing = bodies.ids.find(entity);
        if (existing == bodies.ids.end()) continue;
        removed_constraints += destroy_constraints_for_body(entity);
        bi.RemoveBody(existing->second);
        bi.DestroyBody(existing->second);
        bodies.metadata.erase(entity);
        bodies.signatures.erase(entity);
        kinematic_targets.erase(entity);
        meshes.vertices.erase(entity);
        meshes.indices.erase(entity);
        meshes.revisions.erase(entity);
        bodies.ids.erase(existing);
        ++removed_bodies;
    }

    // Add / refresh bodies in incoming.
    std::vector<uint64_t> incoming_entities;
    incoming_entities.reserve(incoming.size());
    for (const auto& kv : incoming) incoming_entities.push_back(kv.first);
    std::sort(incoming_entities.begin(), incoming_entities.end());

            for (uint64_t entity : incoming_entities) {
                const GuavaJoltBodyDesc& desc = *incoming[entity];
            if (desc.motion_type == kMotionKinematic && desc.has_kinematic_target) {
                kinematic_targets[entity] = NativeKinematicTarget{
                    JPH::RVec3(desc.target_position_x, desc.target_position_y, desc.target_position_z),
                    JPH::Quat(desc.target_rotation_x, desc.target_rotation_y,
                              desc.target_rotation_z, desc.target_rotation_w)
                };
            } else {
                kinematic_targets.erase(entity);
            }
                const std::vector<float>* mv = nullptr;
                const std::vector<uint32_t>* mi = nullptr;
                auto mv_it = meshes.vertices.find(entity);
                auto mi_it = meshes.indices.find(entity);
                if (mv_it != meshes.vertices.end()) mv = &mv_it->second;
                if (mi_it != meshes.indices.end()) mi = &mi_it->second;
                const BodySignature signature = make_signature(desc, mv, mi);

                auto existing = bodies.ids.find(entity);
                if (existing != bodies.ids.end()) {
                    auto previous_signature = bodies.signatures.find(entity);
                    if (previous_signature == bodies.signatures.end()
                        || previous_signature->second != signature) {
                        removed_constraints += destroy_constraints_for_body(entity);
                        destroy_body(entity, bi);
                        ++removed_bodies;
                        if (!create_body(entity, desc, mv, mi, signature, bi)) return false;
                        continue;
                    }

                    // Body already exists — Swift treats the desc as the authoritative
                    // pre-step state each frame (it round-trips state through the engine
                    // every tick). Sync transform/velocity, then queue forces/torques.
                    bi.SetPositionAndRotation(
                existing->second,
                JPH::RVec3(desc.position_x, desc.position_y, desc.position_z),
                JPH::Quat(desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w),
                JPH::EActivation::Activate);
            bi.SetLinearVelocity(existing->second,
                JPH::Vec3(desc.linear_velocity_x, desc.linear_velocity_y, desc.linear_velocity_z));
                    bi.SetAngularVelocity(existing->second,
                        JPH::Vec3(desc.angular_velocity_x, desc.angular_velocity_y, desc.angular_velocity_z));
                    bi.SetFriction(existing->second, desc.friction);
                    bi.SetRestitution(existing->second, desc.restitution);
                    bodies.metadata[entity] = BodyMetadata{
                        (desc.flags & kColliderIsTriggerFlag) != 0,
                        desc.layer_id,
                        desc.layer_mask
                    };
                    if (desc.motion_type == kMotionDynamic) {
                        apply_dynamic_inputs(bi, existing->second, desc);
                    }
                    continue;
                }
                if (!create_body(entity, desc, mv, mi, signature, bi)) return false;
            }
    
            std::unordered_map<uint64_t, const GuavaJoltConstraintDesc*> incoming_constraints;
    if (constraints_in) {
        for (size_t i = 0; i < constraint_count; ++i) {
            incoming_constraints[constraints_in[i].entity_id] = &constraints_in[i];
        }
    }
    std::vector<uint64_t> stale_constraints;
    if (incremental) {
        if (constraint_removal_count > 0) {
            stale_constraints.assign(
                constraint_removals,
                constraint_removals + constraint_removal_count);
        }
        for (const auto& entry : incoming_constraints) {
            if (!entry.second->is_enabled) stale_constraints.push_back(entry.first);
        }
    } else {
        for (const auto& entry : joints.native) {
            auto incoming_constraint = incoming_constraints.find(entry.first);
            if (incoming_constraint == incoming_constraints.end()
                || !incoming_constraint->second->is_enabled) {
                stale_constraints.push_back(entry.first);
            }
        }
    }
    std::sort(stale_constraints.begin(), stale_constraints.end());
    stale_constraints.erase(
        std::unique(stale_constraints.begin(), stale_constraints.end()),
        stale_constraints.end());
    for (uint64_t entity : stale_constraints) {
        if (destroy_constraint(entity)) ++removed_constraints;
    }

    std::vector<uint64_t> incoming_constraint_entities;
    incoming_constraint_entities.reserve(incoming_constraints.size());
    for (const auto& entry : incoming_constraints) incoming_constraint_entities.push_back(entry.first);
    std::sort(incoming_constraint_entities.begin(), incoming_constraint_entities.end());
    for (uint64_t constraint_entity : incoming_constraint_entities) {
            const auto& c = *incoming_constraints[constraint_entity];
            if (!c.is_enabled) continue;
            auto it_a = bodies.ids.find(c.entity_a);
            auto it_b = bodies.ids.find(c.entity_b);
            if (it_a == bodies.ids.end() || it_b == bodies.ids.end()) continue;
            auto previous = joints.descriptors.find(c.entity_id);
            if (joints.native.find(c.entity_id) != joints.native.end()
                && previous != joints.descriptors.end()
                && constraint_desc_equal(previous->second, c)) {
                continue;
            }
            if (destroy_constraint(c.entity_id)) ++removed_constraints;
            JPH::Body* body_a = physics_system.GetBodyLockInterfaceNoLock().TryGetBody(it_a->second);
            JPH::Body* body_b = physics_system.GetBodyLockInterfaceNoLock().TryGetBody(it_b->second);
            if (!body_a || !body_b) continue;

            JPH::Ref<JPH::Constraint> jc;
            if (c.constraint_type == kConstraintPointToPoint) {
                JPH::PointConstraintSettings s;
                s.mPoint1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                s.mPoint2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                s.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
                jc = s.Create(*body_a, *body_b);
            } else if (c.constraint_type == kConstraintHinge) {
                JPH::Vec3 axis1 = safe_normalized(c.axis_a_x, c.axis_a_y, c.axis_a_z, JPH::Vec3::sAxisY());
                JPH::Vec3 axis2 = safe_normalized(c.axis_b_x, c.axis_b_y, c.axis_b_z, axis1);
                JPH::HingeConstraintSettings s;
                s.mPoint1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                s.mPoint2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                s.mHingeAxis1 = axis1;
                s.mHingeAxis2 = axis2;
                s.mNormalAxis1 = perpendicular_axis(axis1);
                s.mNormalAxis2 = perpendicular_axis(axis2);
                s.mLimitsMin = c.min_limit;
                s.mLimitsMax = c.max_limit;
                s.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
                jc = s.Create(*body_a, *body_b);
            } else if (c.constraint_type == kConstraintSlider) {
                JPH::SliderConstraintSettings s;
                s.mPoint1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                s.mPoint2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                s.mSliderAxis1 = safe_normalized(c.axis_a_x, c.axis_a_y, c.axis_a_z, JPH::Vec3::sAxisX());
                s.mSliderAxis2 = safe_normalized(c.axis_b_x, c.axis_b_y, c.axis_b_z, s.mSliderAxis1);
                s.mLimitsMin = c.min_limit;
                s.mLimitsMax = c.max_limit;
                s.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
                jc = s.Create(*body_a, *body_b);
            } else if (c.constraint_type == kConstraintDistance) {
                JPH::DistanceConstraintSettings s;
                s.mPoint1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                s.mPoint2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                s.mMinDistance = c.min_limit;
                s.mMaxDistance = c.max_limit;
                s.mLimitsSpringSettings = JPH::SpringSettings(
                    JPH::ESpringMode::FrequencyAndDamping,
                    c.spring_frequency,
                    c.spring_damping);
                s.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
                jc = s.Create(*body_a, *body_b);
            } else if (c.constraint_type == kConstraintFixed) {
                JPH::Vec3 axis1 = safe_normalized(c.axis_a_x, c.axis_a_y, c.axis_a_z, JPH::Vec3::sAxisX());
                JPH::Vec3 axis2 = safe_normalized(c.axis_b_x, c.axis_b_y, c.axis_b_z, axis1);
                JPH::FixedConstraintSettings s;
                s.mPoint1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                s.mPoint2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                s.mAxisX1 = axis1;
                s.mAxisY1 = perpendicular_axis(axis1);
                s.mAxisX2 = axis2;
                s.mAxisY2 = perpendicular_axis(axis2);
                s.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
                jc = s.Create(*body_a, *body_b);
            } else if (c.constraint_type == kConstraintCone) {
                JPH::Vec3 twist1 = safe_normalized(
                    c.axis_a_x, c.axis_a_y, c.axis_a_z, JPH::Vec3::sAxisX());
                JPH::Vec3 twist2 = safe_normalized(
                    c.axis_b_x, c.axis_b_y, c.axis_b_z, twist1);
                JPH::SwingTwistConstraintSettings s;
                s.mPosition1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                s.mPosition2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                s.mTwistAxis1 = twist1;
                s.mTwistAxis2 = twist2;
                s.mPlaneAxis1 = perpendicular_axis(twist1);
                s.mPlaneAxis2 = perpendicular_axis(twist2);
                s.mSwingType = JPH::ESwingType::Cone;
                s.mNormalHalfConeAngle = c.half_cone_angle;
                s.mPlaneHalfConeAngle = c.half_cone_angle;
                s.mTwistMinAngle = c.min_limit;
                s.mTwistMaxAngle = c.max_limit;
                s.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
                jc = s.Create(*body_a, *body_b);
            } else if (c.constraint_type == kConstraintSixDOF) {
                JPH::Vec3 axis1 = safe_normalized(
                    c.axis_a_x, c.axis_a_y, c.axis_a_z, JPH::Vec3::sAxisX());
                JPH::Vec3 axis2 = safe_normalized(
                    c.axis_b_x, c.axis_b_y, c.axis_b_z, axis1);
                JPH::SixDOFConstraintSettings s;
                s.mPosition1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                s.mPosition2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                s.mAxisX1 = axis1;
                s.mAxisY1 = perpendicular_axis(axis1);
                s.mAxisX2 = axis2;
                s.mAxisY2 = perpendicular_axis(axis2);
                s.SetLimitedAxis(JPH::SixDOFConstraintSettings::EAxis::TranslationX,
                    c.linear_min_x, c.linear_max_x);
                s.SetLimitedAxis(JPH::SixDOFConstraintSettings::EAxis::TranslationY,
                    c.linear_min_y, c.linear_max_y);
                s.SetLimitedAxis(JPH::SixDOFConstraintSettings::EAxis::TranslationZ,
                    c.linear_min_z, c.linear_max_z);
                s.SetLimitedAxis(JPH::SixDOFConstraintSettings::EAxis::RotationX,
                    c.angular_min_x, c.angular_max_x);
                s.SetLimitedAxis(JPH::SixDOFConstraintSettings::EAxis::RotationY,
                    c.angular_min_y, c.angular_max_y);
                s.SetLimitedAxis(JPH::SixDOFConstraintSettings::EAxis::RotationZ,
                    c.angular_min_z, c.angular_max_z);
                for (int axis = 0; axis < JPH::SixDOFConstraintSettings::EAxis::NumTranslation; ++axis) {
                    s.mLimitsSpringSettings[axis] = JPH::SpringSettings(
                        JPH::ESpringMode::FrequencyAndDamping,
                        c.spring_frequency,
                        c.spring_damping);
                }
                s.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
                jc = s.Create(*body_a, *body_b);
            }
            if (jc) {
                if (c.constraint_type == kConstraintHinge) {
                    auto* hinge = static_cast<JPH::HingeConstraint*>(jc.GetPtr());
                    hinge->GetLimitsSpringSettings() = JPH::SpringSettings(
                        JPH::ESpringMode::FrequencyAndDamping,
                        c.spring_frequency,
                        c.spring_damping);
                    hinge->GetMotorSettings().SetTorqueLimit(c.angular_motor_max_force);
                    hinge->SetTargetAngle(c.angular_motor_target_position);
                    hinge->SetTargetAngularVelocity(c.angular_motor_target_velocity);
                    hinge->SetMotorState(motor_state(c.angular_motor_mode));
                } else if (c.constraint_type == kConstraintSlider) {
                    auto* slider = static_cast<JPH::SliderConstraint*>(jc.GetPtr());
                    slider->GetLimitsSpringSettings() = JPH::SpringSettings(
                        JPH::ESpringMode::FrequencyAndDamping,
                        c.spring_frequency,
                        c.spring_damping);
                    slider->GetMotorSettings().SetForceLimit(c.motor_max_force);
                    slider->SetTargetPosition(c.motor_target_position);
                    slider->SetTargetVelocity(c.motor_target_velocity);
                    slider->SetMotorState(motor_state(c.motor_mode));
                } else if (c.constraint_type == kConstraintSixDOF) {
                    auto* six_dof = static_cast<JPH::SixDOFConstraint*>(jc.GetPtr());
                    for (int axis = 0; axis < JPH::SixDOFConstraintSettings::EAxis::NumTranslation; ++axis) {
                        const auto value = static_cast<JPH::SixDOFConstraint::EAxis>(axis);
                        six_dof->GetMotorSettings(value).SetForceLimit(c.motor_max_force);
                        six_dof->SetMotorState(value, motor_state(c.motor_mode));
                    }
                    for (int axis = JPH::SixDOFConstraintSettings::EAxis::RotationX;
                         axis < JPH::SixDOFConstraintSettings::EAxis::Num; ++axis) {
                        const auto value = static_cast<JPH::SixDOFConstraint::EAxis>(axis);
                        six_dof->GetMotorSettings(value).SetTorqueLimit(c.angular_motor_max_force);
                        six_dof->SetMotorState(value, motor_state(c.angular_motor_mode));
                    }
                    six_dof->SetTargetPositionCS(JPH::Vec3::sReplicate(c.motor_target_position));
                    six_dof->SetTargetVelocityCS(JPH::Vec3::sReplicate(c.motor_target_velocity));
                    six_dof->SetTargetAngularVelocityCS(
                        JPH::Vec3::sReplicate(c.angular_motor_target_velocity));
                }
                physics_system.AddConstraint(jc);
                joints.native[c.entity_id] = jc;
                joints.descriptors[c.entity_id] = c;
                joints.bodies[c.entity_id] = {c.entity_a, c.entity_b};
            }
    }

    if (out_stats) {
        out_stats->synchronized_bodies = incremental
            ? static_cast<uint32_t>(body_count)
            : static_cast<uint32_t>(bodies.ids.size());
        out_stats->synchronized_constraints = incremental
            ? static_cast<uint32_t>(constraint_count)
            : static_cast<uint32_t>(joints.native.size());
        out_stats->removed_bodies = removed_bodies;
        out_stats->removed_constraints = removed_constraints;
    }
    return true;
    }

bool GuavaJoltContextImpl::step(const GuavaJoltStepConfig* config, GuavaJoltBodyState* states, size_t state_count, GuavaJoltStepStats* out_stats) {
            last_error = GUAVA_JOLT_ERROR_NONE;
            if (!config || !out_stats || (state_count > 0 && !states)) {
        last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
        return false;
    }
    physics_system.SetGravity(JPH::Vec3(config->gravity_x, config->gravity_y, config->gravity_z));

    std::unordered_map<uint64_t, GuavaJoltBodyState> input_states;
    input_states.reserve(state_count);
    for (size_t index = 0; index < state_count; ++index) {
        input_states[states[index].entity_id] = states[index];
    }

    JPH::BodyInterface& body_interface = physics_system.GetBodyInterface();
    std::vector<uint64_t> target_entities;
    target_entities.reserve(kinematic_targets.size());
    for (const auto& item : kinematic_targets) target_entities.push_back(item.first);
    std::sort(target_entities.begin(), target_entities.end());
    for (uint64_t entity : target_entities) {
        auto body_it = bodies.ids.find(entity);
        if (body_it == bodies.ids.end()) continue;
        const NativeKinematicTarget& target = kinematic_targets[entity];
        body_interface.MoveKinematic(
            body_it->second,
            target.position,
            target.rotation,
            config->delta_seconds);
    }

    const int collision_steps = static_cast<int>(std::max<uint32_t>(1u, config->collision_steps));
    physics_system.Update(config->delta_seconds, collision_steps,
                          temp_allocator.get(), job_system.get());
    if (!apply_soft_body_self_collisions(config->delta_seconds)) return false;

    // Jolt exposes accumulated constraint impulses. Convert them to force /
    // torque for this fixed step and remove joints that exceeded authored
    // break thresholds in deterministic joint-entity order.
    std::vector<uint64_t> joint_ids;
    joint_ids.reserve(joints.native.size());
    for (const auto& entry : joints.native) joint_ids.push_back(entry.first);
    std::sort(joint_ids.begin(), joint_ids.end());
    std::vector<uint64_t> broken_joints;
    const float inverse_delta = config->delta_seconds > 0.0f ? 1.0f / config->delta_seconds : 0.0f;
    for (uint64_t joint_entity : joint_ids) {
        auto constraint_it = joints.native.find(joint_entity);
        auto descriptor_it = joints.descriptors.find(joint_entity);
        if (constraint_it == joints.native.end() || descriptor_it == joints.descriptors.end()) continue;
        const GuavaJoltConstraintDesc& desc = descriptor_it->second;
        float force_impulse = 0.0f;
        float torque_impulse = 0.0f;
        JPH::Constraint* base = constraint_it->second.GetPtr();
        switch (desc.constraint_type) {
        case kConstraintPointToPoint:
            force_impulse = static_cast<JPH::PointConstraint*>(base)->GetTotalLambdaPosition().Length();
            break;
        case kConstraintHinge: {
            auto* value = static_cast<JPH::HingeConstraint*>(base);
            force_impulse = value->GetTotalLambdaPosition().Length();
            torque_impulse = value->GetTotalLambdaRotation().Length()
                + std::abs(value->GetTotalLambdaRotationLimits())
                + std::abs(value->GetTotalLambdaMotor());
            break;
        }
        case kConstraintSlider: {
            auto* value = static_cast<JPH::SliderConstraint*>(base);
            force_impulse = value->GetTotalLambdaPosition().Length()
                + std::abs(value->GetTotalLambdaPositionLimits())
                + std::abs(value->GetTotalLambdaMotor());
            torque_impulse = value->GetTotalLambdaRotation().Length();
            break;
        }
        case kConstraintDistance:
            force_impulse = std::abs(
                static_cast<JPH::DistanceConstraint*>(base)->GetTotalLambdaPosition());
            break;
        case kConstraintFixed: {
            auto* value = static_cast<JPH::FixedConstraint*>(base);
            force_impulse = value->GetTotalLambdaPosition().Length();
            torque_impulse = value->GetTotalLambdaRotation().Length();
            break;
        }
        case kConstraintCone: {
            auto* value = static_cast<JPH::SwingTwistConstraint*>(base);
            force_impulse = value->GetTotalLambdaPosition().Length();
            const float twist = value->GetTotalLambdaTwist();
            const float swing_y = value->GetTotalLambdaSwingY();
            const float swing_z = value->GetTotalLambdaSwingZ();
            torque_impulse = std::sqrt(twist * twist + swing_y * swing_y + swing_z * swing_z);
            break;
        }
        case kConstraintSixDOF: {
            auto* value = static_cast<JPH::SixDOFConstraint*>(base);
            force_impulse = value->GetTotalLambdaPosition().Length()
                + value->GetTotalLambdaMotorTranslation().Length();
            torque_impulse = value->GetTotalLambdaRotation().Length()
                + value->GetTotalLambdaMotorRotation().Length();
            break;
        }
        default:
            break;
        }
        // Some constraint implementations can report a zero accumulated
        // lambda after a position-only correction. Preserve break semantics
        // with a deterministic positional-error estimate in that case.
        if (force_impulse <= 1.0e-8f) {
            auto bodies_it = joints.bodies.find(joint_entity);
            if (bodies_it != joints.bodies.end()) {
                auto body_a_it = bodies.ids.find(bodies_it->second.first);
                auto body_b_it = bodies.ids.find(bodies_it->second.second);
                if (body_a_it != bodies.ids.end() && body_b_it != bodies.ids.end()) {
                    const JPH::RVec3 position_a = body_interface.GetCenterOfMassPosition(body_a_it->second);
                    const JPH::RVec3 position_b = body_interface.GetCenterOfMassPosition(body_b_it->second);
                    const float separation = static_cast<float>((position_b - position_a).Length());
                    float positional_error = 0.0f;
                    if (desc.constraint_type == kConstraintDistance) {
                        positional_error = std::max(
                            std::max(desc.min_limit - separation, separation - desc.max_limit),
                            0.0f);
                    } else if (desc.constraint_type == kConstraintPointToPoint
                               || desc.constraint_type == kConstraintFixed
                               || desc.constraint_type == kConstraintCone) {
                        positional_error = separation;
                    }
                    force_impulse = positional_error * inverse_delta;
                }
            }
        }
        const float force = force_impulse * inverse_delta;
        const float torque = torque_impulse * inverse_delta;
        if (force > desc.break_force || torque > desc.break_torque) {
            events.joint_break_events.push_back(GuavaJoltJointBreakEvent{
                joint_entity, desc.entity_a, desc.entity_b, force, torque
            });
            broken_joints.push_back(joint_entity);
        }
    }
    for (uint64_t joint_entity : broken_joints) destroy_constraint(joint_entity);

    // Write back states in deterministic entity_id order (matches existing semantics).
    std::vector<uint64_t> ids;
    ids.reserve(bodies.ids.size());
    for (auto& kv : bodies.ids) ids.push_back(kv.first);
    std::sort(ids.begin(), ids.end());

    JPH::BodyInterface& bi = physics_system.GetBodyInterface();
    size_t written = 0;
    for (uint64_t entity : ids) {
        if (written >= state_count) break;
        GuavaJoltBodyState candidate {};
        fill_state_from_body(candidate, entity, bi, bodies.ids[entity]);
        auto previous = input_states.find(entity);
        if (previous == input_states.end()
            || body_state_changed(previous->second, candidate)) {
            states[written] = candidate;
            ++written;
        }
    }

    out_stats->body_count = static_cast<uint32_t>(bodies.ids.size());
    out_stats->constraint_count = static_cast<uint32_t>(joints.native.size());
    out_stats->contact_count = events.contact_listener.event_count();
    out_stats->state_count = static_cast<uint32_t>(written);
    out_stats->success = 1;
    out_stats->reserved0 = 0;
            out_stats->reserved1 = 0;
            return true;
        }

