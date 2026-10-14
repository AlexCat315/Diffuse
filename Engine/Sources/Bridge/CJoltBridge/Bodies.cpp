#include "Internal.hpp"

using namespace jolt;

// Rigid body creation, teardown and identity lookup.


bool GuavaJoltContextImpl::create_body(uint64_t entity, const GuavaJoltBodyDesc& desc, const std::vector<float>* mv, const std::vector<uint32_t>* mi, const BodySignature& signature, JPH::BodyInterface& bi) {
    const bool contains_non_convex_mesh = [&desc]() {
        if ((desc.flags & kColliderHasMeshFlag) != 0) return true;
        for (uint32_t index = 0; index < desc.shape_instance_count; ++index) {
            const uint8_t type = desc.shape_instances[index].shape_type;
            if (type == 4 || type == 6) return true;
        }
        return false;
    }();
    if (desc.motion_type == kMotionDynamic && contains_non_convex_mesh) {
        last_error = GUAVA_JOLT_ERROR_INVALID_SHAPE;
        return false;
    }

    JPH::ShapeRefC shape = build_shape(
        desc,
        mv ? mv->data() : nullptr,
        mv ? static_cast<uint32_t>(mv->size() / 3) : 0u,
        mi ? mi->data() : nullptr,
        mi ? static_cast<uint32_t>(mi->size()) : 0u);
    if (!shape) {
        last_error = GUAVA_JOLT_ERROR_INVALID_SHAPE;
        return false;
    }
    if (desc.has_center_of_mass_override) {
        JPH::OffsetCenterOfMassShapeSettings center_settings(
            JPH::Vec3(desc.center_of_mass_x, desc.center_of_mass_y, desc.center_of_mass_z),
            shape);
        JPH::ShapeSettings::ShapeResult centered = center_settings.Create();
        if (!centered.IsValid()) {
            last_error = GUAVA_JOLT_ERROR_INVALID_SHAPE;
            return false;
        }
        shape = centered.Get();
    }

    JPH::EMotionType motion = to_motion_type(desc.motion_type);
    if ((desc.flags & kColliderIsTriggerFlag) != 0
        && motion == JPH::EMotionType::Static) {
        motion = JPH::EMotionType::Kinematic;
    }
    // Sensors must participate in broadphase pairs even when authored without
    // a RigidBody (static-static pairs are normally suppressed by Jolt).
    JPH::ObjectLayer layer = (desc.flags & kColliderIsTriggerFlag) != 0
        ? Layers::MOVING
        : object_layer_for(motion);

    JPH::BodyCreationSettings settings(
        shape,
        JPH::RVec3(desc.position_x, desc.position_y, desc.position_z),
        JPH::Quat(desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w),
        motion,
        layer);
    settings.mUserData = entity;
    settings.mLinearVelocity = JPH::Vec3(
        desc.linear_velocity_x, desc.linear_velocity_y, desc.linear_velocity_z);
    settings.mAngularVelocity = JPH::Vec3(
        desc.angular_velocity_x, desc.angular_velocity_y, desc.angular_velocity_z);
    settings.mLinearDamping = desc.linear_damping;
    settings.mAngularDamping = desc.angular_damping;
    settings.mGravityFactor = desc.gravity_scale;
    settings.mFriction = desc.friction;
    settings.mRestitution = desc.restitution;
    settings.mIsSensor = (desc.flags & kColliderIsTriggerFlag) != 0;
    settings.mCollideKinematicVsNonDynamic = settings.mIsSensor;
    settings.mAllowSleeping = (desc.flags & kRigidBodyAllowSleepFlag) != 0;
    settings.mAllowedDOFs = static_cast<JPH::EAllowedDOFs>(desc.allowed_dofs);
    settings.mMaxLinearVelocity = std::max(desc.max_linear_velocity, 0.0f);
    settings.mMaxAngularVelocity = std::max(desc.max_angular_velocity, 0.0f);
    if (motion == JPH::EMotionType::Dynamic
        && (desc.flags & kRigidBodyContinuousCollisionFlag) != 0) {
        settings.mMotionQuality = JPH::EMotionQuality::LinearCast;
    }
    if (motion == JPH::EMotionType::Dynamic) {
        if (desc.allowed_dofs == 0) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
        if (desc.has_inertia_override) {
            settings.mOverrideMassProperties = JPH::EOverrideMassProperties::MassAndInertiaProvided;
            settings.mMassPropertiesOverride.mMass = std::max(desc.mass, 0.0001f);
            settings.mMassPropertiesOverride.mInertia = JPH::Mat44::sScale(JPH::Vec3(
                std::max(desc.inertia_x, 0.0001f),
                std::max(desc.inertia_y, 0.0001f),
                std::max(desc.inertia_z, 0.0001f)));
        } else if (desc.mass_mode == 1) {
            settings.mOverrideMassProperties = JPH::EOverrideMassProperties::CalculateMassAndInertia;
        } else {
            settings.mOverrideMassProperties = JPH::EOverrideMassProperties::CalculateInertia;
            settings.mMassPropertiesOverride.mMass = std::max(desc.mass, 0.0001f);
        }
    }

    JPH::Body* body = bi.CreateBody(settings);
    if (!body) {
        last_error = GUAVA_JOLT_ERROR_BODY_CREATION_FAILED;
        return false;
    }

    bodies.metadata[entity] = BodyMetadata{
        (desc.flags & kColliderIsTriggerFlag) != 0,
        desc.layer_id,
        desc.layer_mask
    };
    bi.AddBody(body->GetID(), JPH::EActivation::Activate);
    bodies.ids[entity] = body->GetID();
    bodies.signatures[entity] = signature;
    if (motion == JPH::EMotionType::Dynamic) {
        apply_dynamic_inputs(bi, body->GetID(), desc);
    }
    return true;
    }

void GuavaJoltContextImpl::destroy_body(uint64_t entity, JPH::BodyInterface& bi) {
    auto existing = bodies.ids.find(entity);
    if (existing == bodies.ids.end()) return;
    destroy_vehicle(entity);
    bi.RemoveBody(existing->second);
    bi.DestroyBody(existing->second);
    bodies.ids.erase(existing);
    bodies.metadata.erase(entity);
    bodies.signatures.erase(entity);
    kinematic_targets.erase(entity);
    }

bool GuavaJoltContextImpl::entity_for_body_id(JPH::BodyID body_id, uint64_t& out_entity) const {
    if (body_id.IsInvalid()) return false;
    for (const auto& entry : bodies.ids) {
        if (entry.second == body_id) {
            out_entity = entry.first;
            return true;
        }
    }
    for (const auto& entry : soft_bodies.ids) {
        if (entry.second == body_id) {
            out_entity = entry.first;
            return true;
        }
    }
    return false;
    }

