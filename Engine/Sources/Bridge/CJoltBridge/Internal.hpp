#pragma once

#include "include/jolt_bridge.h"


// Jolt requires this single-include guard pattern.
#include <Jolt/Jolt.h>

#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Collision/Shape/MeshShape.h>
#include <Jolt/Physics/Collision/Shape/ConvexHullShape.h>
#include <Jolt/Physics/Collision/Shape/RotatedTranslatedShape.h>
#include <Jolt/Physics/Collision/Shape/ScaledShape.h>
#include <Jolt/Physics/Collision/Shape/StaticCompoundShape.h>
#include <Jolt/Physics/Collision/Shape/OffsetCenterOfMassShape.h>
#include <Jolt/Physics/Collision/CollisionCollectorImpl.h>
#include <Jolt/Physics/Collision/NarrowPhaseQuery.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/ShapeCast.h>
#include <Jolt/Physics/Collision/CollideShape.h>
#include <Jolt/Physics/Collision/ContactListener.h>
#include <Jolt/Physics/Collision/EstimateCollisionResponse.h>
#include <Jolt/Physics/Character/CharacterVirtual.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Body/BodyLock.h>
#include <Jolt/Physics/Body/BodyFilter.h>
#include <Jolt/Physics/Constraints/PointConstraint.h>
#include <Jolt/Physics/Constraints/HingeConstraint.h>
#include <Jolt/Physics/Constraints/FixedConstraint.h>
#include <Jolt/Physics/Constraints/SliderConstraint.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>
#include <Jolt/Physics/Constraints/SwingTwistConstraint.h>
#include <Jolt/Physics/Constraints/SixDOFConstraint.h>
#include <Jolt/Physics/Vehicle/VehicleConstraint.h>
#include <Jolt/Physics/Vehicle/VehicleCollisionTester.h>
#include <Jolt/Physics/Vehicle/WheeledVehicleController.h>
#include <Jolt/Physics/Vehicle/TrackedVehicleController.h>
#include <Jolt/Physics/Vehicle/MotorcycleController.h>
#include <Jolt/Physics/SoftBody/SoftBodyCreationSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodyMotionProperties.h>
#include <Jolt/Physics/SoftBody/SoftBodySharedSettings.h>
#include <Jolt/Geometry/ClosestPoint.h>

#include <atomic>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <thread>

// Private implementation types shared by the CJoltBridge translation units.
// Nothing here crosses the C ABI declared in include/jolt_bridge.h.
namespace jolt {


// Bridge flag constants (must match Swift `JoltPhysicsBackend`).
constexpr uint32_t kColliderHasBoxFlag     = 1u << 0;
constexpr uint32_t kColliderHasSphereFlag  = 1u << 1;
constexpr uint32_t kColliderHasMeshFlag    = 1u << 2;
constexpr uint32_t kColliderIsTriggerFlag  = 1u << 3;
constexpr uint32_t kRigidBodyAllowSleepFlag = 1u << 4;
constexpr uint32_t kColliderHasCapsuleFlag = 1u << 5;
constexpr uint32_t kColliderHasConvexFlag  = 1u << 6;
constexpr uint32_t kRigidBodyContinuousCollisionFlag = 1u << 7;
constexpr uint32_t kColliderHasCylinderFlag = 1u << 8;

constexpr uint32_t kMotionStatic    = 0u;
constexpr uint32_t kMotionDynamic   = 1u;
constexpr uint32_t kMotionKinematic = 2u;

constexpr uint8_t kConstraintPointToPoint = 0u;
constexpr uint8_t kConstraintHinge        = 1u;
constexpr uint8_t kConstraintSlider       = 2u;
constexpr uint8_t kConstraintDistance     = 3u;
constexpr uint8_t kConstraintFixed        = 4u;
constexpr uint8_t kConstraintCone         = 5u;
constexpr uint8_t kConstraintSixDOF       = 6u;

constexpr uint8_t kTriggerEnter = 0u;
constexpr uint8_t kTriggerExit  = 1u;
constexpr uint8_t kTriggerActive = 2u;

constexpr uint8_t kContactBegan = 0u;
constexpr uint8_t kContactPersisted = 1u;
constexpr uint8_t kContactEnded = 2u;

constexpr uint8_t kQueryShapeBox = 0u;
constexpr uint8_t kQueryShapeSphere = 1u;
constexpr uint8_t kQueryShapeCapsule = 2u;

// Layer setup — minimal two-layer scheme (non-moving + moving).
namespace Layers {
    static constexpr JPH::ObjectLayer NON_MOVING = 0;
    static constexpr JPH::ObjectLayer MOVING     = 1;
    static constexpr JPH::ObjectLayer NUM_LAYERS = 2;
}

namespace BPLayers {
    static constexpr JPH::BroadPhaseLayer NON_MOVING { 0 };
    static constexpr JPH::BroadPhaseLayer MOVING     { 1 };
    static constexpr JPH::uint NUM_LAYERS = 2;
}

struct BodyMetadata {
    bool is_trigger = false;
    uint16_t layer_id = 0;
    uint16_t layer_mask = UINT16_MAX;
};

struct SoftBodySelfCollisionFace {
    std::array<uint32_t, 3> vertices {};
};

struct NativeSoftBodySelfCollision {
    float vertex_radius = 0.0f;
    float cell_size = 0.0f;
    std::vector<SoftBodySelfCollisionFace> faces;
    std::unordered_set<uint64_t> topology_edges;
};

struct SoftBodySelfCollisionCell {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;

    bool operator==(const SoftBodySelfCollisionCell& other) const {
        return x == other.x && y == other.y && z == other.z;
    }
};

struct SoftBodySelfCollisionCellHash {
    size_t operator()(const SoftBodySelfCollisionCell& cell) const noexcept {
        size_t value = std::hash<int32_t>{}(cell.x);
        value ^= std::hash<int32_t>{}(cell.y) + 0x9e3779b9u + (value << 6) + (value >> 2);
        value ^= std::hash<int32_t>{}(cell.z) + 0x9e3779b9u + (value << 6) + (value >> 2);
        return value;
    }
};

struct BodySignature {
    uint32_t motion_type = 0;
    uint32_t flags = 0;
    float box_half_extent_x = 0.0f;
    float box_half_extent_y = 0.0f;
    float box_half_extent_z = 0.0f;
    float sphere_radius = 0.0f;
    float capsule_radius = 0.0f;
    float capsule_half_height = 0.0f;
    float shape_center_x = 0.0f;
    float shape_center_y = 0.0f;
    float shape_center_z = 0.0f;
    float shape_scale_x = 1.0f;
    float shape_scale_y = 1.0f;
    float shape_scale_z = 1.0f;
    float mass = 0.0f;
    float gravity_scale = 0.0f;
    float linear_damping = 0.0f;
    float angular_damping = 0.0f;
    uint16_t layer_id = 0;
    uint16_t layer_mask = UINT16_MAX;
    float friction = 0.0f;
    float restitution = 0.0f;
    uint32_t mesh_vertex_count = 0;
    uint32_t mesh_index_count = 0;
    uint64_t mesh_hash = 0;
    uint32_t shape_instance_count = 0;
    uint64_t shape_instance_hash = 0;
    uint8_t mass_mode = 0;
    uint8_t motion_quality = 0;
    uint8_t allowed_dofs = 0x3f;
    uint8_t has_center_of_mass_override = 0;
    uint8_t has_inertia_override = 0;
    float max_linear_velocity = 0.0f;
    float max_angular_velocity = 0.0f;
    JPH::Vec3 center_of_mass = JPH::Vec3::sZero();
    JPH::Vec3 inertia = JPH::Vec3::sZero();

    bool operator==(const BodySignature& other) const {
        return motion_type == other.motion_type
            && flags == other.flags
            && box_half_extent_x == other.box_half_extent_x
            && box_half_extent_y == other.box_half_extent_y
            && box_half_extent_z == other.box_half_extent_z
            && sphere_radius == other.sphere_radius
            && capsule_radius == other.capsule_radius
            && capsule_half_height == other.capsule_half_height
            && shape_center_x == other.shape_center_x
            && shape_center_y == other.shape_center_y
            && shape_center_z == other.shape_center_z
            && shape_scale_x == other.shape_scale_x
            && shape_scale_y == other.shape_scale_y
            && shape_scale_z == other.shape_scale_z
            && mass == other.mass
            && gravity_scale == other.gravity_scale
            && linear_damping == other.linear_damping
            && angular_damping == other.angular_damping
            && layer_id == other.layer_id
            && layer_mask == other.layer_mask
            && friction == other.friction
            && restitution == other.restitution
            && mesh_vertex_count == other.mesh_vertex_count
            && mesh_index_count == other.mesh_index_count
            && mesh_hash == other.mesh_hash
            && shape_instance_count == other.shape_instance_count
            && shape_instance_hash == other.shape_instance_hash
            && mass_mode == other.mass_mode
            && motion_quality == other.motion_quality
            && allowed_dofs == other.allowed_dofs
            && has_center_of_mass_override == other.has_center_of_mass_override
            && has_inertia_override == other.has_inertia_override
            && max_linear_velocity == other.max_linear_velocity
            && max_angular_velocity == other.max_angular_velocity
            && center_of_mass == other.center_of_mass
            && inertia == other.inertia;
    }

    bool operator!=(const BodySignature& other) const {
        return !(*this == other);
    }
};

struct TriggerPair {
    uint64_t trigger = 0;
    uint64_t other = 0;

    bool operator==(const TriggerPair& rhs) const {
        return trigger == rhs.trigger && other == rhs.other;
    }
};

struct TriggerPairHash {
    size_t operator()(const TriggerPair& pair) const {
        size_t h1 = std::hash<uint64_t>{}(pair.trigger);
        size_t h2 = std::hash<uint64_t>{}(pair.other);
        return h1 ^ (h2 + 0x9e3779b97f4a7c15ull + (h1 << 6) + (h1 >> 2));
    }
};

struct PendingContactEvent {
    uint64_t entity_a = 0;
    uint64_t entity_b = 0;
    uint8_t kind = kContactBegan;
    uint32_t sub_shape_id_a = 0;
    uint32_t sub_shape_id_b = 0;
    JPH::RVec3 position = JPH::RVec3::sZero();
    JPH::Vec3 normal = JPH::Vec3::sZero();
    float penetration_depth = 0.0f;
    JPH::Vec3 relative_velocity = JPH::Vec3::sZero();
    float impulse = 0.0f;
};

struct ActiveContactPair {
    uint64_t entity_a = 0;
    uint64_t entity_b = 0;
    uint32_t sub_shape_id_a = 0;
    uint32_t sub_shape_id_b = 0;
};

inline uint64_t hash_mesh_data(const std::vector<float>* vertices, const std::vector<uint32_t>* indices) {
    uint64_t hash = 1469598103934665603ull;
    auto mix_byte = [&hash](uint8_t byte) {
        hash ^= byte;
        hash *= 1099511628211ull;
    };
    if (vertices) {
        const uint8_t* bytes = reinterpret_cast<const uint8_t*>(vertices->data());
        size_t count = vertices->size() * sizeof(float);
        for (size_t i = 0; i < count; ++i) mix_byte(bytes[i]);
    }
    if (indices) {
        const uint8_t* bytes = reinterpret_cast<const uint8_t*>(indices->data());
        size_t count = indices->size() * sizeof(uint32_t);
        for (size_t i = 0; i < count; ++i) mix_byte(bytes[i]);
    }
    return hash;
}

inline uint64_t hash_shape_instances(const GuavaJoltShapeInstance* instances, uint32_t count) {
    if (!instances || count == 0) return 0;
    uint64_t hash = 1469598103934665603ull;
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(instances);
    const size_t byte_count = sizeof(GuavaJoltShapeInstance) * count;
    for (size_t index = 0; index < byte_count; ++index) {
        hash ^= bytes[index];
        hash *= 1099511628211ull;
    }
    return hash;
}

inline BodySignature make_signature(const GuavaJoltBodyDesc& desc,
                             const std::vector<float>* vertices,
                             const std::vector<uint32_t>* indices) {
    BodySignature signature;
    signature.motion_type = desc.motion_type;
    signature.flags = desc.flags;
    signature.box_half_extent_x = desc.box_half_extent_x;
    signature.box_half_extent_y = desc.box_half_extent_y;
    signature.box_half_extent_z = desc.box_half_extent_z;
    signature.sphere_radius = desc.sphere_radius;
    signature.capsule_radius = desc.capsule_radius;
    signature.capsule_half_height = desc.capsule_half_height;
    signature.shape_center_x = desc.shape_center_x;
    signature.shape_center_y = desc.shape_center_y;
    signature.shape_center_z = desc.shape_center_z;
    signature.shape_scale_x = desc.shape_scale_x;
    signature.shape_scale_y = desc.shape_scale_y;
    signature.shape_scale_z = desc.shape_scale_z;
    signature.mass = desc.mass;
    signature.gravity_scale = desc.gravity_scale;
    signature.linear_damping = desc.linear_damping;
    signature.angular_damping = desc.angular_damping;
    signature.layer_id = desc.layer_id;
    signature.layer_mask = desc.layer_mask;
    signature.friction = desc.friction;
    signature.restitution = desc.restitution;
    signature.mesh_vertex_count = vertices ? static_cast<uint32_t>(vertices->size() / 3) : 0u;
    signature.mesh_index_count = indices ? static_cast<uint32_t>(indices->size()) : 0u;
    signature.mesh_hash = hash_mesh_data(vertices, indices);
    signature.shape_instance_count = desc.shape_instance_count;
    signature.shape_instance_hash = hash_shape_instances(
        desc.shape_instances,
        desc.shape_instance_count);
    signature.mass_mode = desc.mass_mode;
    signature.motion_quality = desc.motion_quality;
    signature.allowed_dofs = desc.allowed_dofs;
    signature.has_center_of_mass_override = desc.has_center_of_mass_override;
    signature.has_inertia_override = desc.has_inertia_override;
    signature.max_linear_velocity = desc.max_linear_velocity;
    signature.max_angular_velocity = desc.max_angular_velocity;
    signature.center_of_mass = JPH::Vec3(desc.center_of_mass_x, desc.center_of_mass_y, desc.center_of_mass_z);
    signature.inertia = JPH::Vec3(desc.inertia_x, desc.inertia_y, desc.inertia_z);
    return signature;
}

inline bool layers_overlap(uint16_t mask, uint16_t layer_id) {
    if (mask == UINT16_MAX) return true;
    if (layer_id >= 16) return false;
    return (mask & (uint16_t(1) << layer_id)) != 0;
}

inline bool body_layers_collide(const BodyMetadata& a, const BodyMetadata& b) {
    return layers_overlap(a.layer_mask, b.layer_id)
        && layers_overlap(b.layer_mask, a.layer_id);
}

inline bool constraint_desc_equal(const GuavaJoltConstraintDesc& a, const GuavaJoltConstraintDesc& b) {
    return a.entity_a == b.entity_a
        && a.entity_b == b.entity_b
        && a.constraint_type == b.constraint_type
        && a.is_enabled == b.is_enabled
        && a.pivot_a_x == b.pivot_a_x
        && a.pivot_a_y == b.pivot_a_y
        && a.pivot_a_z == b.pivot_a_z
        && a.pivot_b_x == b.pivot_b_x
        && a.pivot_b_y == b.pivot_b_y
        && a.pivot_b_z == b.pivot_b_z
        && a.axis_a_x == b.axis_a_x
        && a.axis_a_y == b.axis_a_y
        && a.axis_a_z == b.axis_a_z
        && a.axis_b_x == b.axis_b_x
        && a.axis_b_y == b.axis_b_y
        && a.axis_b_z == b.axis_b_z
        && a.min_limit == b.min_limit
        && a.max_limit == b.max_limit
        && a.break_force == b.break_force
        && a.break_torque == b.break_torque
        && a.spring_frequency == b.spring_frequency
        && a.spring_damping == b.spring_damping
        && a.motor_mode == b.motor_mode
        && a.angular_motor_mode == b.angular_motor_mode
        && a.motor_target_position == b.motor_target_position
        && a.motor_target_velocity == b.motor_target_velocity
        && a.motor_max_force == b.motor_max_force
        && a.angular_motor_target_position == b.angular_motor_target_position
        && a.angular_motor_target_velocity == b.angular_motor_target_velocity
        && a.angular_motor_max_force == b.angular_motor_max_force
        && a.half_cone_angle == b.half_cone_angle
        && a.linear_min_x == b.linear_min_x
        && a.linear_min_y == b.linear_min_y
        && a.linear_min_z == b.linear_min_z
        && a.linear_max_x == b.linear_max_x
        && a.linear_max_y == b.linear_max_y
        && a.linear_max_z == b.linear_max_z
        && a.angular_min_x == b.angular_min_x
        && a.angular_min_y == b.angular_min_y
        && a.angular_min_z == b.angular_min_z
        && a.angular_max_x == b.angular_max_x
        && a.angular_max_y == b.angular_max_y
        && a.angular_max_z == b.angular_max_z;
}

inline JPH::EMotorState motor_state(uint8_t value) {
    if (value == 1) return JPH::EMotorState::Velocity;
    if (value == 2) return JPH::EMotorState::Position;
    return JPH::EMotorState::Off;
}

inline bool query_filter_matches(uint64_t entity, const BodyMetadata& metadata, const GuavaJoltQueryFilter* filter) {
    if (!filter) return true;
    if (filter->has_exclude_entity && filter->exclude_entity == entity) return false;
    if (!filter->include_triggers && metadata.is_trigger) return false;
    if (filter->has_layer_id && metadata.layer_id != filter->layer_id) return false;
    return (metadata.layer_mask & filter->layer_mask) != 0;
}

class MetadataBodyFilter final : public JPH::BodyFilter {
public:
    MetadataBodyFilter(const std::unordered_map<uint64_t, BodyMetadata>& metadata,
                       const GuavaJoltQueryFilter* filter)
        : mMetadata(metadata), mFilter(filter) {}

    bool ShouldCollideLocked(const JPH::Body& inBody) const override {
        const uint64_t entity = inBody.GetUserData();
        auto it = mMetadata.find(entity);
        if (it == mMetadata.end()) return false;
        return query_filter_matches(entity, it->second, mFilter);
    }

private:
    const std::unordered_map<uint64_t, BodyMetadata>& mMetadata;
    const GuavaJoltQueryFilter* mFilter;
};

class TriggerBodyFilter final : public JPH::BodyFilter {
public:
    TriggerBodyFilter(const std::unordered_map<uint64_t, BodyMetadata>& metadata,
                      uint64_t trigger_entity,
                      const BodyMetadata& trigger_metadata)
        : mMetadata(metadata), mTriggerEntity(trigger_entity), mTriggerMetadata(trigger_metadata) {}

    bool ShouldCollideLocked(const JPH::Body& inBody) const override {
        const uint64_t other = inBody.GetUserData();
        if (other == mTriggerEntity) return false;
        auto it = mMetadata.find(other);
        if (it == mMetadata.end()) return false;
        const BodyMetadata& other_metadata = it->second;
        if (other_metadata.is_trigger) return false;
        return layers_overlap(mTriggerMetadata.layer_mask, other_metadata.layer_id);
    }

private:
    const std::unordered_map<uint64_t, BodyMetadata>& mMetadata;
    uint64_t mTriggerEntity;
    BodyMetadata mTriggerMetadata;
};

class CharacterMetadataBodyFilter final : public JPH::BodyFilter {
public:
    CharacterMetadataBodyFilter(
        const std::unordered_map<uint64_t, BodyMetadata>& metadata,
        uint16_t character_layer,
        uint16_t character_mask)
        : mMetadata(metadata), mCharacterLayer(character_layer), mCharacterMask(character_mask) {}

    bool ShouldCollideLocked(const JPH::Body& inBody) const override {
        auto it = mMetadata.find(inBody.GetUserData());
        if (it == mMetadata.end() || it->second.is_trigger) return false;
        return layers_overlap(mCharacterMask, it->second.layer_id)
            && layers_overlap(it->second.layer_mask, mCharacterLayer);
    }

private:
    const std::unordered_map<uint64_t, BodyMetadata>& mMetadata;
    uint16_t mCharacterLayer;
    uint16_t mCharacterMask;
};

class LayerMaskContactListener final : public JPH::ContactListener {
public:
    explicit LayerMaskContactListener(const std::unordered_map<uint64_t, BodyMetadata>& metadata)
        : mMetadata(metadata) {}

    JPH::ValidateResult OnContactValidate(const JPH::Body& body1,
                                          const JPH::Body& body2,
                                          JPH::RVec3Arg,
                                          const JPH::CollideShapeResult&) override {
        const uint64_t entity1 = body1.GetUserData();
        const uint64_t entity2 = body2.GetUserData();
        auto it1 = mMetadata.find(entity1);
        auto it2 = mMetadata.find(entity2);
        if (it1 == mMetadata.end() || it2 == mMetadata.end()) {
            return JPH::ValidateResult::RejectAllContactsForThisBodyPair;
        }
        if (!body_layers_collide(it1->second, it2->second)) {
            return JPH::ValidateResult::RejectAllContactsForThisBodyPair;
        }
        return JPH::ValidateResult::AcceptAllContactsForThisBodyPair;
    }

    void OnContactAdded(const JPH::Body& body1,
                        const JPH::Body& body2,
                        const JPH::ContactManifold& manifold,
                        JPH::ContactSettings& settings) override {
        record_contact(kContactBegan, body1, body2, manifold, settings);
    }

    void OnContactPersisted(const JPH::Body& body1,
                            const JPH::Body& body2,
                            const JPH::ContactManifold& manifold,
                            JPH::ContactSettings& settings) override {
        record_contact(kContactPersisted, body1, body2, manifold, settings);
    }

    void OnContactRemoved(const JPH::SubShapeIDPair& sub_shape_pair) override {
        std::lock_guard<std::mutex> lock(mMutex);
        auto it = mActiveContacts.find(sub_shape_pair);
        if (it == mActiveContacts.end()) return;

        mEvents.push_back(PendingContactEvent{
            it->second.entity_a,
            it->second.entity_b,
            kContactEnded,
            it->second.sub_shape_id_a,
            it->second.sub_shape_id_b,
            JPH::RVec3::sZero(),
            JPH::Vec3::sZero(),
            0.0f,
            JPH::Vec3::sZero(),
            0.0f
        });
        mActiveContacts.erase(it);
    }

    void begin_step() {
        std::lock_guard<std::mutex> lock(mMutex);
        mEvents.clear();
    }

    void reset() {
        std::lock_guard<std::mutex> lock(mMutex);
        mEvents.clear();
        mActiveContacts.clear();
    }

    uint32_t event_count() const {
        std::lock_guard<std::mutex> lock(mMutex);
        return static_cast<uint32_t>(mEvents.size());
    }

    uint32_t copy_events(GuavaJoltContactEvent* out_events, size_t event_capacity) const {
        std::vector<PendingContactEvent> events;
        {
            std::lock_guard<std::mutex> lock(mMutex);
            events = mEvents;
        }
        std::sort(events.begin(), events.end(), [](const auto& lhs, const auto& rhs) {
            if (lhs.entity_a != rhs.entity_a) return lhs.entity_a < rhs.entity_a;
            if (lhs.entity_b != rhs.entity_b) return lhs.entity_b < rhs.entity_b;
            if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
            if (lhs.position.GetX() != rhs.position.GetX()) return lhs.position.GetX() < rhs.position.GetX();
            if (lhs.position.GetY() != rhs.position.GetY()) return lhs.position.GetY() < rhs.position.GetY();
            return lhs.position.GetZ() < rhs.position.GetZ();
        });

        const size_t count = std::min(event_capacity, events.size());
        if (out_events) {
            for (size_t i = 0; i < count; ++i) {
                const auto& event = events[i];
                out_events[i].entity_a = event.entity_a;
                out_events[i].entity_b = event.entity_b;
                out_events[i].kind = event.kind;
                out_events[i].reserved0 = 0;
                out_events[i].reserved1 = 0;
                out_events[i].sub_shape_id_a = event.sub_shape_id_a;
                out_events[i].sub_shape_id_b = event.sub_shape_id_b;
                out_events[i].position_x = event.position.GetX();
                out_events[i].position_y = event.position.GetY();
                out_events[i].position_z = event.position.GetZ();
                out_events[i].normal_x = event.normal.GetX();
                out_events[i].normal_y = event.normal.GetY();
                out_events[i].normal_z = event.normal.GetZ();
                out_events[i].penetration_depth = event.penetration_depth;
                out_events[i].relative_velocity_x = event.relative_velocity.GetX();
                out_events[i].relative_velocity_y = event.relative_velocity.GetY();
                out_events[i].relative_velocity_z = event.relative_velocity.GetZ();
                out_events[i].impulse = event.impulse;
            }
        }
        return static_cast<uint32_t>(events.size());
    }

private:
    bool should_record_contact(uint64_t entity1, uint64_t entity2) const {
        auto it1 = mMetadata.find(entity1);
        auto it2 = mMetadata.find(entity2);
        if (it1 == mMetadata.end() || it2 == mMetadata.end()) return false;
        return body_layers_collide(it1->second, it2->second);
    }

    JPH::RVec3 contact_position(const JPH::ContactManifold& manifold) const {
        if (manifold.mRelativeContactPointsOn1.empty()) return manifold.mBaseOffset;
        JPH::RVec3 point1 = manifold.GetWorldSpaceContactPointOn1(0);
        JPH::RVec3 point2 = manifold.GetWorldSpaceContactPointOn2(0);
        return JPH::RVec3(
            (point1.GetX() + point2.GetX()) * 0.5,
            (point1.GetY() + point2.GetY()) * 0.5,
            (point1.GetZ() + point2.GetZ()) * 0.5
        );
    }

    void record_contact(uint8_t kind,
                        const JPH::Body& body1,
                        const JPH::Body& body2,
                        const JPH::ContactManifold& manifold,
                        const JPH::ContactSettings& settings) {
        const uint64_t entity1 = body1.GetUserData();
        const uint64_t entity2 = body2.GetUserData();
        if (!should_record_contact(entity1, entity2)) return;

        JPH::SubShapeIDPair sub_shape_pair(
            body1.GetID(),
            manifold.mSubShapeID1,
            body2.GetID(),
            manifold.mSubShapeID2
        );
        float contact_impulse = 0.0f;
        auto metadata1 = mMetadata.find(entity1);
        auto metadata2 = mMetadata.find(entity2);
        if (metadata1 != mMetadata.end() && metadata2 != mMetadata.end()
            && !metadata1->second.is_trigger && !metadata2->second.is_trigger
            && !manifold.mRelativeContactPointsOn1.empty()) {
            JPH::CollisionEstimationResult estimation;
            JPH::EstimateCollisionResponse(
                body1,
                body2,
                manifold,
                estimation,
                settings.mCombinedFriction,
                settings.mCombinedRestitution,
                1.0f,
                4);
            for (float impulse : estimation.mContactImpulse) {
                contact_impulse += std::max(0.0f, impulse);
            }
        }

        PendingContactEvent event{
            entity1,
            entity2,
            kind,
            manifold.mSubShapeID1.GetValue(),
            manifold.mSubShapeID2.GetValue(),
            contact_position(manifold),
            manifold.mWorldSpaceNormal,
            manifold.mPenetrationDepth,
            body2.GetPointVelocity(contact_position(manifold))
                - body1.GetPointVelocity(contact_position(manifold)),
            contact_impulse
        };

        std::lock_guard<std::mutex> lock(mMutex);
        mActiveContacts[sub_shape_pair] = ActiveContactPair{
            entity1,
            entity2,
            manifold.mSubShapeID1.GetValue(),
            manifold.mSubShapeID2.GetValue()
        };
        mEvents.push_back(event);
    }

    const std::unordered_map<uint64_t, BodyMetadata>& mMetadata;
    mutable std::mutex mMutex;
    std::vector<PendingContactEvent> mEvents;
    std::unordered_map<JPH::SubShapeIDPair, ActiveContactPair> mActiveContacts;
};

class BPLayerInterfaceImpl final : public JPH::BroadPhaseLayerInterface {
public:
    BPLayerInterfaceImpl() {
        mMap[Layers::NON_MOVING] = BPLayers::NON_MOVING;
        mMap[Layers::MOVING]     = BPLayers::MOVING;
    }
    JPH::uint GetNumBroadPhaseLayers() const override { return BPLayers::NUM_LAYERS; }
    JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer inLayer) const override {
        return mMap[inLayer];
    }
#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    const char* GetBroadPhaseLayerName(JPH::BroadPhaseLayer) const override { return "?"; }
#endif
private:
    JPH::BroadPhaseLayer mMap[Layers::NUM_LAYERS];
};

class ObjectVsBPLayerFilterImpl final : public JPH::ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer inObject, JPH::BroadPhaseLayer inBroad) const override {
        if (inObject == Layers::NON_MOVING) return inBroad == BPLayers::MOVING;
        return true;
    }
};

class ObjectLayerPairFilterImpl final : public JPH::ObjectLayerPairFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer a, JPH::ObjectLayer b) const override {
        if (a == Layers::NON_MOVING) return b == Layers::MOVING;
        return true;
    }
};

// Process-wide initialization (Factory + Types) is performed exactly once. The
// once_flag stays translation-unit local, so Context.cpp holds the only definition.
void ensure_jolt_initialized();

inline JPH::EMotionType to_motion_type(uint32_t raw) {
    if (raw == kMotionDynamic)   return JPH::EMotionType::Dynamic;
    if (raw == kMotionKinematic) return JPH::EMotionType::Kinematic;
    return JPH::EMotionType::Static;
}

inline JPH::ObjectLayer object_layer_for(JPH::EMotionType m) {
    return (m == JPH::EMotionType::Static) ? Layers::NON_MOVING : Layers::MOVING;
}

inline JPH::Vec3 safe_normalized(float x, float y, float z, JPH::Vec3 fallback) {
    JPH::Vec3 v(x, y, z);
    float len_sq = v.LengthSq();
    return len_sq > 1.0e-8f ? v / sqrtf(len_sq) : fallback;
}

inline JPH::Vec3 perpendicular_axis(JPH::Vec3 axis) {
    JPH::Vec3 candidate = fabsf(axis.Dot(JPH::Vec3::sAxisX())) < 0.9f
        ? JPH::Vec3::sAxisX()
        : JPH::Vec3::sAxisZ();
    return axis.Cross(candidate).Normalized();
}

inline JPH::Vec3 shape_center_for(const GuavaJoltBodyDesc& desc) {
    return JPH::Vec3(desc.shape_center_x, desc.shape_center_y, desc.shape_center_z);
}

inline JPH::Vec3 shape_scale_for(const GuavaJoltBodyDesc& desc) {
    return JPH::Vec3(desc.shape_scale_x, desc.shape_scale_y, desc.shape_scale_z);
}

inline JPH::Vec3 scaled_center(JPH::Vec3Arg center, JPH::Vec3Arg scale) {
    return JPH::Vec3(
        center.GetX() * scale.GetX(),
        center.GetY() * scale.GetY(),
        center.GetZ() * scale.GetZ());
}

inline JPH::Vec3 conservative_uniform_scale(JPH::Vec3Arg scale) {
    const JPH::Vec3 abs_scale = scale.Abs();
    float uniform_scale = std::max(abs_scale.GetX(), std::max(abs_scale.GetY(), abs_scale.GetZ()));
    uniform_scale = std::max(uniform_scale, 1.0e-6f);
    return JPH::Vec3::sReplicate(uniform_scale);
}

inline bool is_identity_scale(JPH::Vec3Arg scale) {
    return fabsf(scale.GetX() - 1.0f) <= 1.0e-6f
        && fabsf(scale.GetY() - 1.0f) <= 1.0e-6f
        && fabsf(scale.GetZ() - 1.0f) <= 1.0e-6f;
}

inline JPH::ShapeRefC with_shape_center(JPH::Vec3Arg center, JPH::ShapeRefC shape) {
    if (!shape) return nullptr;
    if (center.LengthSq() <= 1.0e-12f) return shape;

    JPH::RotatedTranslatedShapeSettings settings(center, JPH::Quat::sIdentity(), shape);
    settings.SetEmbedded();
    JPH::ShapeSettings::ShapeResult result = settings.Create();
    return result.IsValid() ? result.Get() : nullptr;
}

inline JPH::ShapeRefC with_shape_scale(JPH::Vec3Arg scale, JPH::ShapeRefC shape) {
    if (!shape) return nullptr;
    if (is_identity_scale(scale)) return shape;

    JPH::ScaledShapeSettings settings(shape.GetPtr(), scale);
    settings.SetEmbedded();
    JPH::ShapeSettings::ShapeResult result = settings.Create();
    return result.IsValid() ? result.Get() : nullptr;
}

inline JPH::ShapeRefC finalize_shape(const GuavaJoltBodyDesc& desc, JPH::ShapeRefC shape) {
    if (!shape) return nullptr;

    const JPH::Vec3 center = shape_center_for(desc);
    const JPH::Vec3 requested_scale = shape_scale_for(desc);

    if (shape->IsValidScale(requested_scale)) {
        const JPH::Vec3 valid_scale = shape->MakeScaleValid(requested_scale);
        return with_shape_scale(valid_scale, with_shape_center(center, shape));
    }

    JPH::ShapeRefC scaled_shape = with_shape_scale(conservative_uniform_scale(requested_scale), shape);
    return with_shape_center(scaled_center(center, requested_scale), scaled_shape);
}

// Build a Shape from the descriptor's flag+geom fields. Returns null if unsupported.
inline JPH::ShapeRefC build_shape(const GuavaJoltBodyDesc& desc,
                            const float* mesh_vertices, uint32_t mesh_vertex_count,
                            const uint32_t* mesh_indices, uint32_t mesh_index_count) {
    if (desc.shape_instance_count > 0) {
        if (!desc.shape_instances) return nullptr;
        JPH::StaticCompoundShapeSettings compound;
        for (uint32_t index = 0; index < desc.shape_instance_count; ++index) {
            const GuavaJoltShapeInstance& instance = desc.shape_instances[index];
            GuavaJoltBodyDesc child {};
            child.density = desc.density;
            child.shape_scale_x = instance.scale_x;
            child.shape_scale_y = instance.scale_y;
            child.shape_scale_z = instance.scale_z;
            switch (instance.shape_type) {
            case 0:
                child.flags = kColliderHasBoxFlag;
                child.box_half_extent_x = instance.half_extent_x;
                child.box_half_extent_y = instance.half_extent_y;
                child.box_half_extent_z = instance.half_extent_z;
                break;
            case 1:
                child.flags = kColliderHasSphereFlag;
                child.sphere_radius = instance.radius;
                break;
            case 2:
                child.flags = kColliderHasCapsuleFlag;
                child.capsule_radius = instance.radius;
                child.capsule_half_height = instance.half_height;
                break;
            case 3:
                child.flags = kColliderHasCylinderFlag;
                child.capsule_radius = instance.radius;
                child.capsule_half_height = instance.half_height;
                break;
            case 4:
            case 6:
                child.flags = kColliderHasMeshFlag;
                break;
            case 5:
                child.flags = kColliderHasConvexFlag;
                break;
            default:
                return nullptr;
            }
            JPH::ShapeRefC child_shape = build_shape(
                child,
                mesh_vertices,
                mesh_vertex_count,
                mesh_indices,
                mesh_index_count);
            if (!child_shape) return nullptr;
            compound.AddShape(
                JPH::Vec3(instance.position_x, instance.position_y, instance.position_z),
                JPH::Quat(instance.rotation_x, instance.rotation_y, instance.rotation_z, instance.rotation_w),
                child_shape);
        }
        JPH::ShapeSettings::ShapeResult result = compound.Create();
        return result.IsValid() ? result.Get() : nullptr;
    }
    if (desc.flags & kColliderHasBoxFlag) {
        JPH::BoxShapeSettings settings(JPH::Vec3(
            desc.box_half_extent_x, desc.box_half_extent_y, desc.box_half_extent_z));
        settings.mDensity = std::max(desc.density, 0.0001f);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if (desc.flags & kColliderHasSphereFlag) {
        JPH::SphereShapeSettings settings(desc.sphere_radius);
        settings.mDensity = std::max(desc.density, 0.0001f);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if (desc.flags & kColliderHasCapsuleFlag) {
        JPH::CapsuleShapeSettings settings(desc.capsule_half_height, desc.capsule_radius);
        settings.mDensity = std::max(desc.density, 0.0001f);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if (desc.flags & kColliderHasCylinderFlag) {
        JPH::CylinderShapeSettings settings(desc.capsule_half_height, desc.capsule_radius);
        settings.mDensity = std::max(desc.density, 0.0001f);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if ((desc.flags & kColliderHasMeshFlag) && mesh_vertices && mesh_vertex_count > 0
        && mesh_indices && mesh_index_count >= 3) {
        JPH::TriangleList triangles;
        triangles.reserve(mesh_index_count / 3);
        for (uint32_t i = 0; i + 2 < mesh_index_count; i += 3) {
            uint32_t ia = mesh_indices[i + 0];
            uint32_t ib = mesh_indices[i + 1];
            uint32_t ic = mesh_indices[i + 2];
            if (ia >= mesh_vertex_count || ib >= mesh_vertex_count || ic >= mesh_vertex_count) continue;
            JPH::Float3 va(mesh_vertices[ia*3+0], mesh_vertices[ia*3+1], mesh_vertices[ia*3+2]);
            JPH::Float3 vb(mesh_vertices[ib*3+0], mesh_vertices[ib*3+1], mesh_vertices[ib*3+2]);
            JPH::Float3 vc(mesh_vertices[ic*3+0], mesh_vertices[ic*3+1], mesh_vertices[ic*3+2]);
            triangles.push_back(JPH::Triangle(va, vb, vc));
        }
        if (triangles.empty()) return nullptr;
        JPH::MeshShapeSettings settings(std::move(triangles));
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if ((desc.flags & kColliderHasConvexFlag) && mesh_vertices && mesh_vertex_count > 0) {
        JPH::Array<JPH::Vec3> points;
        points.reserve(mesh_vertex_count);
        for (uint32_t i = 0; i < mesh_vertex_count; ++i) {
            points.emplace_back(mesh_vertices[i*3+0], mesh_vertices[i*3+1], mesh_vertices[i*3+2]);
        }
        JPH::ConvexHullShapeSettings settings(points);
        settings.mDensity = std::max(desc.density, 0.0001f);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    return nullptr;
}

inline JPH::Quat normalized_quat(float x, float y, float z, float w) {
    const float len_sq = x * x + y * y + z * z + w * w;
    if (len_sq <= 1.0e-8f) return JPH::Quat::sIdentity();
    const float inv_len = 1.0f / sqrtf(len_sq);
    return JPH::Quat(x * inv_len, y * inv_len, z * inv_len, w * inv_len);
}

inline JPH::ShapeRefC build_query_shape(uint8_t shape_type,
                                 float box_half_extent_x,
                                 float box_half_extent_y,
                                 float box_half_extent_z,
                                 float sphere_radius,
                                 float capsule_radius,
                                 float capsule_half_height) {
    if (shape_type == kQueryShapeBox) {
        JPH::Vec3 half_extents(
            std::max(box_half_extent_x, 0.0f),
            std::max(box_half_extent_y, 0.0f),
            std::max(box_half_extent_z, 0.0f));
        if (half_extents.GetX() <= 0.0f || half_extents.GetY() <= 0.0f || half_extents.GetZ() <= 0.0f) {
            return nullptr;
        }
        JPH::BoxShapeSettings settings(half_extents);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult result = settings.Create();
        return result.IsValid() ? result.Get() : nullptr;
    }

    if (shape_type == kQueryShapeSphere) {
        if (sphere_radius <= 0.0f) return nullptr;
        JPH::SphereShapeSettings settings(sphere_radius);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult result = settings.Create();
        return result.IsValid() ? result.Get() : nullptr;
    }

    if (shape_type == kQueryShapeCapsule) {
        if (capsule_radius <= 0.0f || capsule_half_height < 0.0f) return nullptr;
        JPH::CapsuleShapeSettings settings(capsule_half_height, capsule_radius);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult result = settings.Create();
        return result.IsValid() ? result.Get() : nullptr;
    }

    return nullptr;
}

inline JPH::RMat44 query_transform(float position_x,
                            float position_y,
                            float position_z,
                            float rotation_x,
                            float rotation_y,
                            float rotation_z,
                            float rotation_w) {
    return JPH::RMat44::sRotationTranslation(
        normalized_quat(rotation_x, rotation_y, rotation_z, rotation_w),
        JPH::RVec3(position_x, position_y, position_z));
}

inline void apply_dynamic_inputs(JPH::BodyInterface& bi,
                          const JPH::BodyID& body_id,
                          const GuavaJoltBodyDesc& desc) {
    bi.AddForce(body_id, JPH::Vec3(
        desc.accumulated_force_x, desc.accumulated_force_y, desc.accumulated_force_z));
    bi.AddTorque(body_id, JPH::Vec3(
        desc.accumulated_torque_x, desc.accumulated_torque_y, desc.accumulated_torque_z));
    bi.AddImpulse(body_id, JPH::Vec3(
        desc.accumulated_linear_impulse_x,
        desc.accumulated_linear_impulse_y,
        desc.accumulated_linear_impulse_z));
    bi.AddAngularImpulse(body_id, JPH::Vec3(
        desc.accumulated_angular_impulse_x,
        desc.accumulated_angular_impulse_y,
        desc.accumulated_angular_impulse_z));
}

inline void fill_state_from_body(GuavaJoltBodyState& state, uint64_t entity_id,
                          JPH::BodyInterface& bi, const JPH::BodyID& id) {
    JPH::RVec3 pos = bi.GetPosition(id);
    JPH::Quat rot = bi.GetRotation(id);
    JPH::Vec3 lv = bi.GetLinearVelocity(id);
    JPH::Vec3 av = bi.GetAngularVelocity(id);
    state.entity_id = entity_id;
    state.position_x = pos.GetX(); state.position_y = pos.GetY(); state.position_z = pos.GetZ();
    state.rotation_x = rot.GetX(); state.rotation_y = rot.GetY();
    state.rotation_z = rot.GetZ(); state.rotation_w = rot.GetW();
    state.linear_velocity_x = lv.GetX(); state.linear_velocity_y = lv.GetY(); state.linear_velocity_z = lv.GetZ();
    state.angular_velocity_x = av.GetX(); state.angular_velocity_y = av.GetY(); state.angular_velocity_z = av.GetZ();
    state.is_sleeping = bi.IsActive(id) ? 0u : 1u;
    state.reserved0 = 0;
    state.reserved1 = 0;
}

inline void fill_bounds(const JPH::AABox& bounds,
                 float& min_x, float& min_y, float& min_z,
                 float& max_x, float& max_y, float& max_z) {
    min_x = bounds.mMin.GetX();
    min_y = bounds.mMin.GetY();
    min_z = bounds.mMin.GetZ();
    max_x = bounds.mMax.GetX();
    max_y = bounds.mMax.GetY();
    max_z = bounds.mMax.GetZ();
}

inline bool body_state_changed(const GuavaJoltBodyState& before, const GuavaJoltBodyState& after) {
    return before.position_x != after.position_x
        || before.position_y != after.position_y
        || before.position_z != after.position_z
        || before.rotation_x != after.rotation_x
        || before.rotation_y != after.rotation_y
        || before.rotation_z != after.rotation_z
        || before.rotation_w != after.rotation_w
        || before.linear_velocity_x != after.linear_velocity_x
        || before.linear_velocity_y != after.linear_velocity_y
        || before.linear_velocity_z != after.linear_velocity_z
        || before.angular_velocity_x != after.angular_velocity_x
        || before.angular_velocity_y != after.angular_velocity_y
        || before.angular_velocity_z != after.angular_velocity_z
        || before.is_sleeping != after.is_sleeping;
}

inline JPH::AABox make_aabb(float min_x, float min_y, float min_z,
                     float max_x, float max_y, float max_z) {
    return JPH::AABox(
        JPH::Vec3(std::min(min_x, max_x), std::min(min_y, max_y), std::min(min_z, max_z)),
        JPH::Vec3(std::max(min_x, max_x), std::max(min_y, max_y), std::max(min_z, max_z))
    );
}

inline JPH::Vec3 safe_normalized(JPH::Vec3 value, JPH::Vec3 fallback) {
    float len_sq = value.LengthSq();
    return len_sq > 1.0e-8f ? value / sqrtf(len_sq) : fallback;
}


// --- entity handles the context keeps for simulated entity families ---

    struct NativeKinematicTarget {
        JPH::RVec3 position;
        JPH::Quat rotation;
    };
    struct NativeCharacter {
        std::unique_ptr<JPH::CharacterVirtual> character;
        GuavaJoltCharacterDesc desc {};
        uint8_t stance = 0;
    };
    struct NativeVehicle {
        JPH::Ref<JPH::VehicleConstraint> constraint;
        uint32_t wheel_count = 0;
        uint32_t forward_gear_count = 0;
        uint32_t reverse_gear_count = 0;
        bool uses_manual_transmission = false;
        uint8_t controller_type = 0;
    };

}  // namespace jolt

// Defined at global scope because include/jolt_bridge.h forward declares the
// name in order to expose `GuavaJoltContext` as an opaque pointer to Swift.
// Its implementation files open `using namespace jolt;` so members resolve the
// internal helpers above without qualifying every reference.
// The Jolt handles and cached descriptors that let `prepare` recognise an
// unchanged entity frame to frame instead of rebuilding its body every tick.
// The three maps are only ever read and written as one set.
struct BodyIndex {
    std::unordered_map<uint64_t, JPH::BodyID> ids;
    std::unordered_map<uint64_t, jolt::BodyMetadata> metadata;
    std::unordered_map<uint64_t, jolt::BodySignature> signatures;
};

// Soft bodies track an extra self-collision topology cache alongside their handle.
struct SoftBodyIndex {
    std::unordered_map<uint64_t, JPH::BodyID> ids;
    std::unordered_map<uint64_t, jolt::NativeSoftBodySelfCollision> self_collisions;
};

// A constraint is always reconciled together with its descriptor and the body
// pair it joins, so the three are stored as one unit.
struct ConstraintIndex {
    std::unordered_map<uint64_t, JPH::Ref<JPH::Constraint>> native;
    std::unordered_map<uint64_t, GuavaJoltConstraintDesc> descriptors;
    std::unordered_map<uint64_t, std::pair<uint64_t, uint64_t>> bodies;
};

// Collider mesh geometry, keyed by entity and refreshed only when the explicit
// revision Swift supplies changes.
struct MeshGeometryCache {
    std::unordered_map<uint64_t, std::vector<float>> vertices;
    std::unordered_map<uint64_t, std::vector<uint32_t>> indices;
    std::unordered_map<uint64_t, uint64_t> revisions;
};

// Everything the simulation observes and reports back to Swift for one frame.
// The contact listener keeps a reference to the body metadata, so the plumbing
// is constructed from it once `bodies` exists.
struct EventPlumbing {
    explicit EventPlumbing(const std::unordered_map<uint64_t, jolt::BodyMetadata>& body_metadata)
        : contact_listener(body_metadata) {}

    jolt::LayerMaskContactListener contact_listener;
    std::unordered_set<jolt::TriggerPair, jolt::TriggerPairHash> previous_trigger_pairs;
    std::vector<GuavaJoltJointBreakEvent> joint_break_events;
};

struct GuavaJoltContextImpl {
    jolt::BPLayerInterfaceImpl bp_layer_interface;
    jolt::ObjectVsBPLayerFilterImpl object_vs_bp_filter;
    jolt::ObjectLayerPairFilterImpl object_layer_filter;
    JPH::PhysicsSystem physics_system;
    std::unique_ptr<JPH::TempAllocatorImpl> temp_allocator;
    std::unique_ptr<JPH::JobSystemThreadPool> job_system;

    // Declared before `events` so the contact listener can bind `bodies.metadata`.
    BodyIndex bodies;
    SoftBodyIndex soft_bodies;
    ConstraintIndex joints;
    MeshGeometryCache meshes;
    EventPlumbing events;

    std::unordered_map<uint64_t, jolt::NativeCharacter> characters;
    std::unordered_map<uint64_t, jolt::NativeVehicle> vehicles;
    std::unordered_map<uint64_t, jolt::NativeKinematicTarget> kinematic_targets;

    uint32_t last_error = GUAVA_JOLT_ERROR_NONE;

    explicit GuavaJoltContextImpl(const GuavaJoltContextConfig& config);
    ~GuavaJoltContextImpl();

    // --- context lifecycle ---
    void clear_all();

    // --- rigid bodies ---
    bool create_body(uint64_t entity, const GuavaJoltBodyDesc& desc, const std::vector<float>* mv, const std::vector<uint32_t>* mi, const jolt::BodySignature& signature, JPH::BodyInterface& bi);
    void destroy_body(uint64_t entity, JPH::BodyInterface& bi);
    bool entity_for_body_id(JPH::BodyID body_id, uint64_t& out_entity) const;

    // --- frame synchronization and simulation ---
    bool prepare(const GuavaJoltBodyDesc* body_descs, size_t body_count, const GuavaJoltConstraintDesc* constraints_in, size_t constraint_count, const GuavaJoltMeshGeometry* mesh_geometries, size_t mesh_count, const uint64_t* body_removals, size_t body_removal_count, const uint64_t* constraint_removals, size_t constraint_removal_count, bool incremental, GuavaJoltPrepareStats* out_stats);
    bool step(const GuavaJoltStepConfig* config, GuavaJoltBodyState* states, size_t state_count, GuavaJoltStepStats* out_stats);

    // --- constraints ---
    bool destroy_constraint(uint64_t entity);
    uint32_t destroy_constraints_for_body(uint64_t body_entity);

    // --- characters ---
    static bool character_shape_changed( const GuavaJoltCharacterDesc& lhs, const GuavaJoltCharacterDesc& rhs);
    static JPH::RefConst<JPH::Shape> create_character_shape(float half_height, float radius);
    std::unique_ptr<JPH::CharacterVirtual> create_character(const GuavaJoltCharacterDesc& desc);
    bool sync_characters(const GuavaJoltCharacterDesc* descriptors, size_t count);
    uint32_t step_characters( const GuavaJoltStepConfig* config, const GuavaJoltCharacterCommand* commands, size_t command_count, GuavaJoltCharacterState* out_states, size_t state_capacity);

    // --- vehicles ---
    bool destroy_vehicle(uint64_t entity);
    bool sync_vehicles( const GuavaJoltVehicleDesc* upserts, size_t upsert_count, const uint64_t* removals, size_t removal_count, bool full_snapshot, GuavaJoltVehicleSyncStats* out_stats);
    bool set_vehicle_commands(const GuavaJoltVehicleCommand* commands, size_t command_count);
    uint32_t copy_vehicle_states( GuavaJoltVehicleState* out_states, size_t state_capacity, GuavaJoltVehicleWheelState* out_wheel_states, size_t wheel_state_capacity, uint32_t* out_wheel_state_count) const;

    // --- soft bodies ---
    bool destroy_soft_body(uint64_t entity);
    static int32_t self_collision_cell_coordinate(float value, float cell_size);
    static uint64_t self_collision_edge_key(uint32_t a, uint32_t b);
    static bool self_collision_face_is_adjacent( uint32_t vertex_index, const jolt::SoftBodySelfCollisionFace& face, const std::unordered_set<uint64_t>& topology_edges);
    bool apply_soft_body_self_collisions(float delta_seconds);
    bool create_soft_body(const GuavaJoltSoftBodyDesc& desc);
    bool sync_soft_bodies( const GuavaJoltSoftBodyDesc* upserts, size_t upsert_count, const uint64_t* removals, size_t removal_count, bool full_snapshot, GuavaJoltSoftBodySyncStats* out_stats);
    uint32_t copy_soft_body_states( GuavaJoltSoftBodyState* out_states, size_t state_capacity, float* out_positions_xyz, size_t vertex_capacity, uint32_t* out_vertex_count);

    // --- spatial queries ---
    bool raycast(const GuavaJoltRaycastQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltRaycastHit* out_hit) const;
    uint32_t raycast_all(const GuavaJoltRaycastQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltRaycastHit* out_hits, size_t hit_capacity) const;
    uint32_t overlap_aabb(const GuavaJoltOverlapAABBQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltOverlapHit* out_hits, size_t hit_capacity) const;
    uint32_t overlap_shape(const GuavaJoltOverlapShapeQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltOverlapHit* out_hits, size_t hit_capacity) const;
    bool sweep_aabb(const GuavaJoltSweepAABBQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltSweepHit* out_hit) const;
    bool sweep_shape(const GuavaJoltSweepShapeQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltSweepHit* out_hit) const;
    uint32_t sweep_shape_all(const GuavaJoltSweepShapeQuery* query, const GuavaJoltQueryFilter* filter, GuavaJoltSweepHit* out_hits, size_t hit_capacity) const;

    // --- contact, trigger and joint events ---
    uint32_t detect_triggers(GuavaJoltTriggerEvent* out_events, size_t event_capacity);
    uint32_t copy_contact_events(GuavaJoltContactEvent* out_events, size_t event_capacity) const;
    uint32_t drain_joint_break_events( GuavaJoltJointBreakEvent* out_events, size_t event_capacity);
};
