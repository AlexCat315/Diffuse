#include "jolt_bridge.h"

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
#include <Jolt/Physics/Collision/CollisionCollectorImpl.h>
#include <Jolt/Physics/Collision/NarrowPhaseQuery.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/ShapeCast.h>
#include <Jolt/Physics/Collision/CollideShape.h>
#include <Jolt/Physics/Collision/ContactListener.h>
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

#include <atomic>
#include <algorithm>
#include <cmath>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <thread>

namespace {

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
            && shape_instance_hash == other.shape_instance_hash;
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

uint64_t hash_mesh_data(const std::vector<float>* vertices, const std::vector<uint32_t>* indices) {
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

uint64_t hash_shape_instances(const GuavaJoltShapeInstance* instances, uint32_t count) {
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

BodySignature make_signature(const GuavaJoltBodyDesc& desc,
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
    return signature;
}

bool layers_overlap(uint16_t mask, uint16_t layer_id) {
    if (mask == UINT16_MAX) return true;
    if (layer_id >= 16) return false;
    return (mask & (uint16_t(1) << layer_id)) != 0;
}

bool body_layers_collide(const BodyMetadata& a, const BodyMetadata& b) {
    return layers_overlap(a.layer_mask, b.layer_id)
        && layers_overlap(b.layer_mask, a.layer_id);
}

bool query_filter_matches(uint64_t entity, const BodyMetadata& metadata, const GuavaJoltQueryFilter* filter) {
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
                        JPH::ContactSettings&) override {
        record_contact(kContactBegan, body1, body2, manifold);
    }

    void OnContactPersisted(const JPH::Body& body1,
                            const JPH::Body& body2,
                            const JPH::ContactManifold& manifold,
                            JPH::ContactSettings&) override {
        record_contact(kContactPersisted, body1, body2, manifold);
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
                        const JPH::ContactManifold& manifold) {
        const uint64_t entity1 = body1.GetUserData();
        const uint64_t entity2 = body2.GetUserData();
        if (!should_record_contact(entity1, entity2)) return;

        JPH::SubShapeIDPair sub_shape_pair(
            body1.GetID(),
            manifold.mSubShapeID1,
            body2.GetID(),
            manifold.mSubShapeID2
        );
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
            0.0f
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

// Process-wide initialization (Factory + Types) — called lazily and exactly once.
std::once_flag g_jolt_init;
void ensure_jolt_initialized() {
    std::call_once(g_jolt_init, []() {
        JPH::RegisterDefaultAllocator();
        JPH::Factory::sInstance = new JPH::Factory();
        JPH::RegisterTypes();
    });
}

JPH::EMotionType to_motion_type(uint32_t raw) {
    if (raw == kMotionDynamic)   return JPH::EMotionType::Dynamic;
    if (raw == kMotionKinematic) return JPH::EMotionType::Kinematic;
    return JPH::EMotionType::Static;
}

JPH::ObjectLayer object_layer_for(JPH::EMotionType m) {
    return (m == JPH::EMotionType::Static) ? Layers::NON_MOVING : Layers::MOVING;
}

JPH::Vec3 safe_normalized(float x, float y, float z, JPH::Vec3 fallback) {
    JPH::Vec3 v(x, y, z);
    float len_sq = v.LengthSq();
    return len_sq > 1.0e-8f ? v / sqrtf(len_sq) : fallback;
}

JPH::Vec3 perpendicular_axis(JPH::Vec3 axis) {
    JPH::Vec3 candidate = fabsf(axis.Dot(JPH::Vec3::sAxisX())) < 0.9f
        ? JPH::Vec3::sAxisX()
        : JPH::Vec3::sAxisZ();
    return axis.Cross(candidate).Normalized();
}

JPH::Vec3 shape_center_for(const GuavaJoltBodyDesc& desc) {
    return JPH::Vec3(desc.shape_center_x, desc.shape_center_y, desc.shape_center_z);
}

JPH::Vec3 shape_scale_for(const GuavaJoltBodyDesc& desc) {
    return JPH::Vec3(desc.shape_scale_x, desc.shape_scale_y, desc.shape_scale_z);
}

JPH::Vec3 scaled_center(JPH::Vec3Arg center, JPH::Vec3Arg scale) {
    return JPH::Vec3(
        center.GetX() * scale.GetX(),
        center.GetY() * scale.GetY(),
        center.GetZ() * scale.GetZ());
}

JPH::Vec3 conservative_uniform_scale(JPH::Vec3Arg scale) {
    const JPH::Vec3 abs_scale = scale.Abs();
    float uniform_scale = std::max(abs_scale.GetX(), std::max(abs_scale.GetY(), abs_scale.GetZ()));
    uniform_scale = std::max(uniform_scale, 1.0e-6f);
    return JPH::Vec3::sReplicate(uniform_scale);
}

bool is_identity_scale(JPH::Vec3Arg scale) {
    return fabsf(scale.GetX() - 1.0f) <= 1.0e-6f
        && fabsf(scale.GetY() - 1.0f) <= 1.0e-6f
        && fabsf(scale.GetZ() - 1.0f) <= 1.0e-6f;
}

JPH::ShapeRefC with_shape_center(JPH::Vec3Arg center, JPH::ShapeRefC shape) {
    if (!shape) return nullptr;
    if (center.LengthSq() <= 1.0e-12f) return shape;

    JPH::RotatedTranslatedShapeSettings settings(center, JPH::Quat::sIdentity(), shape);
    settings.SetEmbedded();
    JPH::ShapeSettings::ShapeResult result = settings.Create();
    return result.IsValid() ? result.Get() : nullptr;
}

JPH::ShapeRefC with_shape_scale(JPH::Vec3Arg scale, JPH::ShapeRefC shape) {
    if (!shape) return nullptr;
    if (is_identity_scale(scale)) return shape;

    JPH::ScaledShapeSettings settings(shape.GetPtr(), scale);
    settings.SetEmbedded();
    JPH::ShapeSettings::ShapeResult result = settings.Create();
    return result.IsValid() ? result.Get() : nullptr;
}

JPH::ShapeRefC finalize_shape(const GuavaJoltBodyDesc& desc, JPH::ShapeRefC shape) {
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
JPH::ShapeRefC build_shape(const GuavaJoltBodyDesc& desc,
                            const float* mesh_vertices, uint32_t mesh_vertex_count,
                            const uint32_t* mesh_indices, uint32_t mesh_index_count) {
    if (desc.shape_instance_count > 0) {
        if (!desc.shape_instances) return nullptr;
        JPH::StaticCompoundShapeSettings compound;
        for (uint32_t index = 0; index < desc.shape_instance_count; ++index) {
            const GuavaJoltShapeInstance& instance = desc.shape_instances[index];
            GuavaJoltBodyDesc child {};
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
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if (desc.flags & kColliderHasSphereFlag) {
        JPH::SphereShapeSettings settings(desc.sphere_radius);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if (desc.flags & kColliderHasCapsuleFlag) {
        JPH::CapsuleShapeSettings settings(desc.capsule_half_height, desc.capsule_radius);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    if (desc.flags & kColliderHasCylinderFlag) {
        JPH::CylinderShapeSettings settings(desc.capsule_half_height, desc.capsule_radius);
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
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return finalize_shape(desc, r.Get());
    }
    return nullptr;
}

JPH::Quat normalized_quat(float x, float y, float z, float w) {
    const float len_sq = x * x + y * y + z * z + w * w;
    if (len_sq <= 1.0e-8f) return JPH::Quat::sIdentity();
    const float inv_len = 1.0f / sqrtf(len_sq);
    return JPH::Quat(x * inv_len, y * inv_len, z * inv_len, w * inv_len);
}

JPH::ShapeRefC build_query_shape(uint8_t shape_type,
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

JPH::RMat44 query_transform(float position_x,
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

void apply_dynamic_inputs(JPH::BodyInterface& bi,
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

void fill_state_from_body(GuavaJoltBodyState& state, uint64_t entity_id,
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

void fill_bounds(const JPH::AABox& bounds,
                 float& min_x, float& min_y, float& min_z,
                 float& max_x, float& max_y, float& max_z) {
    min_x = bounds.mMin.GetX();
    min_y = bounds.mMin.GetY();
    min_z = bounds.mMin.GetZ();
    max_x = bounds.mMax.GetX();
    max_y = bounds.mMax.GetY();
    max_z = bounds.mMax.GetZ();
}

JPH::AABox make_aabb(float min_x, float min_y, float min_z,
                     float max_x, float max_y, float max_z) {
    return JPH::AABox(
        JPH::Vec3(std::min(min_x, max_x), std::min(min_y, max_y), std::min(min_z, max_z)),
        JPH::Vec3(std::max(min_x, max_x), std::max(min_y, max_y), std::max(min_z, max_z))
    );
}

JPH::Vec3 safe_normalized(JPH::Vec3 value, JPH::Vec3 fallback) {
    float len_sq = value.LengthSq();
    return len_sq > 1.0e-8f ? value / sqrtf(len_sq) : fallback;
}

}  // namespace

struct GuavaJoltContextImpl {
    struct NativeCharacter {
        std::unique_ptr<JPH::CharacterVirtual> character;
        GuavaJoltCharacterDesc desc {};
        uint8_t stance = 0;
    };
    BPLayerInterfaceImpl bp_layer_interface;
    ObjectVsBPLayerFilterImpl object_vs_bp_filter;
    ObjectLayerPairFilterImpl object_layer_filter;
    JPH::PhysicsSystem physics_system;
    std::unique_ptr<JPH::TempAllocatorImpl> temp_allocator;
    std::unique_ptr<JPH::JobSystemThreadPool> job_system;

    std::unordered_map<uint64_t, JPH::BodyID> body_ids;            // entity → Jolt body
    std::unordered_map<uint64_t, JPH::Ref<JPH::Constraint>> constraints; // entity → constraint
    std::unordered_map<uint64_t, BodyMetadata> body_metadata;
    std::unordered_map<uint64_t, BodySignature> body_signatures;
    std::unordered_map<uint64_t, NativeCharacter> characters;
    std::unordered_map<uint64_t, std::vector<float>>    mesh_vertices;
    std::unordered_map<uint64_t, std::vector<uint32_t>> mesh_indices;
    std::unordered_set<TriggerPair, TriggerPairHash> previous_trigger_pairs;
    LayerMaskContactListener contact_listener;
    uint32_t last_error = GUAVA_JOLT_ERROR_NONE;

    GuavaJoltContextImpl()
        : contact_listener(body_metadata) {
        const JPH::uint cMaxBodies            = 65536;
        const JPH::uint cNumBodyMutexes       = 0;
        const JPH::uint cMaxBodyPairs         = 65536;
        const JPH::uint cMaxContactConstraints = 10240;
        physics_system.Init(cMaxBodies, cNumBodyMutexes, cMaxBodyPairs, cMaxContactConstraints,
                            bp_layer_interface, object_vs_bp_filter, object_layer_filter);
        physics_system.SetContactListener(&contact_listener);
        temp_allocator = std::make_unique<JPH::TempAllocatorImpl>(10 * 1024 * 1024);
        const unsigned hardware_threads = std::thread::hardware_concurrency();
        const int worker_threads = static_cast<int>(hardware_threads > 1 ? hardware_threads - 1 : 1);
        job_system = std::make_unique<JPH::JobSystemThreadPool>(
            JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers, worker_threads);
    }

    ~GuavaJoltContextImpl() {
        physics_system.SetContactListener(nullptr);
        characters.clear();
        // Remove all bodies and constraints before destruction.
        JPH::BodyInterface& bi = physics_system.GetBodyInterface();
        for (auto& kv : body_ids) {
            bi.RemoveBody(kv.second);
            bi.DestroyBody(kv.second);
        }
        for (auto& kv : constraints) {
            if (kv.second) physics_system.RemoveConstraint(kv.second);
        }
    }

    void clear_all() {
        JPH::BodyInterface& bi = physics_system.GetBodyInterface();
        for (auto& kv : constraints) {
            if (kv.second) physics_system.RemoveConstraint(kv.second);
        }
        constraints.clear();
        characters.clear();
        for (auto& kv : body_ids) {
            bi.RemoveBody(kv.second);
            bi.DestroyBody(kv.second);
        }
        body_ids.clear();
        body_metadata.clear();
        body_signatures.clear();
        mesh_vertices.clear();
        mesh_indices.clear();
        previous_trigger_pairs.clear();
        contact_listener.reset();
    }

    void destroy_body(uint64_t entity, JPH::BodyInterface& bi) {
        auto existing = body_ids.find(entity);
        if (existing == body_ids.end()) return;
        bi.RemoveBody(existing->second);
        bi.DestroyBody(existing->second);
        body_ids.erase(existing);
        body_metadata.erase(entity);
        body_signatures.erase(entity);
    }

    bool create_body(uint64_t entity,
                     const GuavaJoltBodyDesc& desc,
                     const std::vector<float>* mv,
                     const std::vector<uint32_t>* mi,
                     const BodySignature& signature,
                     JPH::BodyInterface& bi) {
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

        JPH::EMotionType motion = to_motion_type(desc.motion_type);
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
        settings.mAllowSleeping = (desc.flags & kRigidBodyAllowSleepFlag) != 0;
        if (motion == JPH::EMotionType::Dynamic
            && (desc.flags & kRigidBodyContinuousCollisionFlag) != 0) {
            settings.mMotionQuality = JPH::EMotionQuality::LinearCast;
        }
        if (motion == JPH::EMotionType::Dynamic) {
            settings.mOverrideMassProperties = JPH::EOverrideMassProperties::CalculateInertia;
            settings.mMassPropertiesOverride.mMass = desc.mass > 0.0f ? desc.mass : std::max(desc.density, 1.0f);
        }

        JPH::Body* body = bi.CreateBody(settings);
        if (!body) {
            last_error = GUAVA_JOLT_ERROR_BODY_CREATION_FAILED;
            return false;
        }

        bi.AddBody(body->GetID(), JPH::EActivation::Activate);
        body_ids[entity] = body->GetID();
        body_metadata[entity] = BodyMetadata{
            (desc.flags & kColliderIsTriggerFlag) != 0,
            desc.layer_id,
            desc.layer_mask
        };
        body_signatures[entity] = signature;
        if (motion == JPH::EMotionType::Dynamic) {
            apply_dynamic_inputs(bi, body->GetID(), desc);
        }
        return true;
    }

	    bool prepare(const GuavaJoltBodyDesc* bodies, size_t body_count,
	                 const GuavaJoltConstraintDesc* constraints_in, size_t constraint_count,
	                 const GuavaJoltMeshGeometry* meshes, size_t mesh_count,
	                 GuavaJoltPrepareStats* out_stats) {
	        last_error = GUAVA_JOLT_ERROR_NONE;
        if ((body_count > 0 && !bodies)
            || (constraint_count > 0 && !constraints_in)
            || (mesh_count > 0 && !meshes)) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }

	        // Capture mesh geometry keyed by entity_id (deep-copy so pointers stay valid).
        std::unordered_map<uint64_t, std::pair<const float*, std::pair<uint32_t, std::pair<const uint32_t*, uint32_t>>>> mesh_lookup;
        mesh_vertices.clear();
        mesh_indices.clear();
        if (meshes) {
            for (size_t i = 0; i < mesh_count; ++i) {
                const auto& m = meshes[i];
                if (m.vertices && m.vertex_count > 0) {
                    mesh_vertices[m.entity_id].assign(m.vertices, m.vertices + m.vertex_count * 3);
                }
                if (m.indices && m.index_count > 0) {
                    mesh_indices[m.entity_id].assign(m.indices, m.indices + m.index_count);
                }
            }
        }
	
	        JPH::BodyInterface& bi = physics_system.GetBodyInterface();

	        // Constraints refer to BodyIDs, so drop them before bodies are removed or
	        // recreated and rebuild them after all bodies are synchronized.
	        uint32_t removed_constraints = static_cast<uint32_t>(constraints.size());
	        for (auto& kv : constraints) {
	            if (kv.second) physics_system.RemoveConstraint(kv.second);
	        }
	        constraints.clear();
	
	        // Track which entities are present this frame.
	        std::unordered_map<uint64_t, const GuavaJoltBodyDesc*> incoming;
	        if (bodies) {
	            for (size_t i = 0; i < body_count; ++i) incoming[bodies[i].entity_id] = &bodies[i];
        }

        // Remove bodies no longer present.
	        uint32_t removed_bodies = 0;
	        for (auto it = body_ids.begin(); it != body_ids.end(); ) {
	            if (incoming.find(it->first) == incoming.end()) {
	                bi.RemoveBody(it->second);
	                bi.DestroyBody(it->second);
	                body_metadata.erase(it->first);
	                body_signatures.erase(it->first);
	                it = body_ids.erase(it);
	                ++removed_bodies;
	            } else {
	                ++it;
	            }
        }

        // Add / refresh bodies in incoming.
        std::vector<uint64_t> incoming_entities;
        incoming_entities.reserve(incoming.size());
        for (const auto& kv : incoming) incoming_entities.push_back(kv.first);
        std::sort(incoming_entities.begin(), incoming_entities.end());

	        for (uint64_t entity : incoming_entities) {
	            const GuavaJoltBodyDesc& desc = *incoming[entity];
	            const std::vector<float>* mv = nullptr;
	            const std::vector<uint32_t>* mi = nullptr;
	            auto mv_it = mesh_vertices.find(entity);
	            auto mi_it = mesh_indices.find(entity);
	            if (mv_it != mesh_vertices.end()) mv = &mv_it->second;
	            if (mi_it != mesh_indices.end()) mi = &mi_it->second;
	            const BodySignature signature = make_signature(desc, mv, mi);

	            auto existing = body_ids.find(entity);
	            if (existing != body_ids.end()) {
	                auto previous_signature = body_signatures.find(entity);
	                if (previous_signature == body_signatures.end()
	                    || previous_signature->second != signature) {
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
	                body_metadata[entity] = BodyMetadata{
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
	
	        if (constraints_in) {
            for (size_t i = 0; i < constraint_count; ++i) {
                const auto& c = constraints_in[i];
                if (!c.is_enabled) continue;
                auto it_a = body_ids.find(c.entity_a);
                auto it_b = body_ids.find(c.entity_b);
                if (it_a == body_ids.end() || it_b == body_ids.end()) continue;
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
                }
                if (jc) {
                    physics_system.AddConstraint(jc);
                    constraints[c.entity_id] = jc;
                }
            }
        }

        if (out_stats) {
            out_stats->synchronized_bodies = static_cast<uint32_t>(body_ids.size());
            out_stats->synchronized_constraints = static_cast<uint32_t>(constraints.size());
            out_stats->removed_bodies = removed_bodies;
            out_stats->removed_constraints = removed_constraints;
        }
        return true;
    }

	    bool step(const GuavaJoltStepConfig* config, GuavaJoltBodyState* states, size_t state_count,
	              GuavaJoltStepStats* out_stats) {
	        last_error = GUAVA_JOLT_ERROR_NONE;
	        if (!config || !out_stats || (state_count > 0 && !states)) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }
        physics_system.SetGravity(JPH::Vec3(config->gravity_x, config->gravity_y, config->gravity_z));

        const int collision_steps = static_cast<int>(std::max<uint32_t>(1u, config->collision_steps));
        contact_listener.begin_step();
        physics_system.Update(config->delta_seconds, collision_steps,
                              temp_allocator.get(), job_system.get());

        // Write back states in deterministic entity_id order (matches existing semantics).
        std::vector<uint64_t> ids;
        ids.reserve(body_ids.size());
        for (auto& kv : body_ids) ids.push_back(kv.first);
        std::sort(ids.begin(), ids.end());

        JPH::BodyInterface& bi = physics_system.GetBodyInterface();
        size_t written = 0;
        for (uint64_t entity : ids) {
            if (written >= state_count) break;
            fill_state_from_body(states[written], entity, bi, body_ids[entity]);
            ++written;
        }

        out_stats->body_count = static_cast<uint32_t>(body_ids.size());
        out_stats->constraint_count = static_cast<uint32_t>(constraints.size());
        out_stats->contact_count = contact_listener.event_count();
        out_stats->state_count = static_cast<uint32_t>(written);
        out_stats->success = 1;
        out_stats->reserved0 = 0;
	        out_stats->reserved1 = 0;
	        return true;
	    }

    static bool character_shape_changed(
        const GuavaJoltCharacterDesc& lhs,
        const GuavaJoltCharacterDesc& rhs) {
        return lhs.radius != rhs.radius
            || lhs.standing_half_height != rhs.standing_half_height
            || lhs.crouching_half_height != rhs.crouching_half_height
            || lhs.center_x != rhs.center_x
            || lhs.center_y != rhs.center_y
            || lhs.center_z != rhs.center_z
            || lhs.skin_width != rhs.skin_width;
    }

    static JPH::RefConst<JPH::Shape> create_character_shape(float half_height, float radius) {
        JPH::CapsuleShapeSettings capsule_settings(
            std::max(half_height, 0.01f),
            std::max(radius, 0.01f));
        JPH::ShapeSettings::ShapeResult capsule_result = capsule_settings.Create();
        if (!capsule_result.IsValid()) return nullptr;

        // CharacterVirtual treats its position as the character's ground/foot
        // position. Keep the capsule above that origin as recommended by Jolt.
        const float center_height = std::max(half_height, 0.01f) + std::max(radius, 0.01f);
        JPH::RotatedTranslatedShapeSettings translated_settings(
            JPH::Vec3(0, center_height, 0),
            JPH::Quat::sIdentity(),
            capsule_result.Get());
        JPH::ShapeSettings::ShapeResult translated_result = translated_settings.Create();
        return translated_result.IsValid() ? translated_result.Get() : nullptr;
    }

    std::unique_ptr<JPH::CharacterVirtual> create_character(const GuavaJoltCharacterDesc& desc) {
        JPH::RefConst<JPH::Shape> shape = create_character_shape(
            desc.standing_half_height,
            desc.radius);
        if (shape == nullptr) {
            last_error = GUAVA_JOLT_ERROR_INVALID_SHAPE;
            return nullptr;
        }

        JPH::CharacterVirtualSettings settings;
        settings.mShape = shape;
        settings.mShapeOffset = JPH::Vec3(desc.center_x, desc.center_y, desc.center_z);
        settings.mSupportingVolume = JPH::Plane(
            JPH::Vec3::sAxisY(),
            -2.0f * std::max(desc.standing_half_height, 0.01f));
        settings.mCharacterPadding = std::max(desc.skin_width, 0.001f);
        settings.mMass = std::max(desc.mass, 0.01f);
        settings.mMaxStrength = std::max(desc.max_strength, 0.0f);
        settings.mUp = JPH::Vec3::sAxisY();
        auto character = std::make_unique<JPH::CharacterVirtual>(
            &settings,
            JPH::RVec3(desc.position_x, desc.position_y, desc.position_z),
            JPH::Quat(desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w),
            desc.entity_id,
            &physics_system);
        character->SetMaxSlopeAngle(desc.max_slope_radians);
        return character;
    }

    bool sync_characters(const GuavaJoltCharacterDesc* descriptors, size_t count) {
        last_error = GUAVA_JOLT_ERROR_NONE;
        if (count > 0 && !descriptors) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return false;
        }

        std::unordered_map<uint64_t, const GuavaJoltCharacterDesc*> incoming;
        for (size_t i = 0; i < count; ++i) incoming[descriptors[i].entity_id] = &descriptors[i];
        for (auto it = characters.begin(); it != characters.end();) {
            if (incoming.find(it->first) == incoming.end()) it = characters.erase(it);
            else ++it;
        }

        std::vector<uint64_t> ids;
        ids.reserve(incoming.size());
        for (const auto& item : incoming) ids.push_back(item.first);
        std::sort(ids.begin(), ids.end());
        for (uint64_t entity : ids) {
            const GuavaJoltCharacterDesc& desc = *incoming[entity];
            auto existing = characters.find(entity);
            if (existing == characters.end() || character_shape_changed(existing->second.desc, desc)) {
                auto character = create_character(desc);
                if (!character) return false;
                NativeCharacter native;
                native.character = std::move(character);
                native.desc = desc;
                characters[entity] = std::move(native);
                continue;
            }
            NativeCharacter& native = existing->second;
            native.desc = desc;
            native.character->SetPosition(JPH::RVec3(desc.position_x, desc.position_y, desc.position_z));
            native.character->SetRotation(JPH::Quat(
                desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w));
            native.character->SetMass(std::max(desc.mass, 0.01f));
            native.character->SetMaxStrength(std::max(desc.max_strength, 0.0f));
            native.character->SetMaxSlopeAngle(desc.max_slope_radians);
        }
        return true;
    }

    uint32_t step_characters(
        const GuavaJoltStepConfig* config,
        const GuavaJoltCharacterCommand* commands,
        size_t command_count,
        GuavaJoltCharacterState* out_states,
        size_t state_capacity) {
        if (!config || (command_count > 0 && !commands) || (state_capacity > 0 && !out_states)) {
            last_error = GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
            return 0;
        }
        std::unordered_map<uint64_t, const GuavaJoltCharacterCommand*> commands_by_entity;
        for (size_t i = 0; i < command_count; ++i) {
            commands_by_entity[commands[i].entity_id] = &commands[i];
        }

        std::vector<uint64_t> ids;
        ids.reserve(characters.size());
        for (const auto& item : characters) ids.push_back(item.first);
        std::sort(ids.begin(), ids.end());

        uint32_t written = 0;
        for (uint64_t entity : ids) {
            NativeCharacter& native = characters[entity];
            JPH::CharacterVirtual& character = *native.character;
            CharacterMetadataBodyFilter body_filter(
                body_metadata, native.desc.layer_id, native.desc.layer_mask);
            const auto broadphase_filter = physics_system.GetDefaultBroadPhaseLayerFilter(Layers::MOVING);
            const auto layer_filter = physics_system.GetDefaultLayerFilter(Layers::MOVING);

            const GuavaJoltCharacterCommand* command = nullptr;
            auto command_it = commands_by_entity.find(entity);
            if (command_it != commands_by_entity.end()) command = command_it->second;
            const uint8_t requested_stance = command ? command->stance : native.stance;
            if (requested_stance != native.stance) {
                const float half_height = requested_stance == 1
                    ? native.desc.crouching_half_height
                    : native.desc.standing_half_height;
                JPH::RefConst<JPH::Shape> shape = create_character_shape(
                    half_height,
                    native.desc.radius);
                if (shape != nullptr
                    && character.SetShape(
                        shape,
                        0.0f,
                        broadphase_filter,
                        layer_filter,
                        body_filter,
                        {},
                        *temp_allocator)) {
                    native.stance = requested_stance;
                }
            }

            const JPH::Vec3 gravity(
                config->gravity_x * native.desc.gravity_scale,
                config->gravity_y * native.desc.gravity_scale,
                config->gravity_z * native.desc.gravity_scale);
            const JPH::Vec3 up = character.GetUp();
            JPH::Vec3 velocity = character.GetLinearVelocity();
            float vertical_speed = velocity.Dot(up);
            const bool grounded = character.GetGroundState() == JPH::CharacterBase::EGroundState::OnGround;
            if (grounded && vertical_speed < 0.0f) vertical_speed = 0.0f;
            if (command && command->jump_requested && grounded) {
                vertical_speed = std::max(command->jump_speed, 0.0f);
            } else {
                vertical_speed += gravity.Dot(up) * config->delta_seconds;
            }
            JPH::Vec3 desired = command
                ? JPH::Vec3(command->desired_velocity_x, command->desired_velocity_y, command->desired_velocity_z)
                : JPH::Vec3::sZero();
            desired -= up * desired.Dot(up);
            const JPH::Vec3 ground_velocity = grounded ? character.GetGroundVelocity() : JPH::Vec3::sZero();
            character.SetLinearVelocity(desired + up * vertical_speed + ground_velocity);

            JPH::CharacterVirtual::ExtendedUpdateSettings update_settings;
            update_settings.mWalkStairsStepUp = up * native.desc.step_height;
            update_settings.mStickToFloorStepDown = -up * std::max(native.desc.step_height, native.desc.skin_width);
            character.ExtendedUpdate(
                config->delta_seconds,
                gravity,
                update_settings,
                broadphase_filter,
                layer_filter,
                body_filter,
                {},
                *temp_allocator);

            if (written < state_capacity) {
                const JPH::RVec3 position = character.GetPosition();
                const JPH::Quat rotation = character.GetRotation();
                const JPH::Vec3 current_velocity = character.GetLinearVelocity();
                const JPH::Vec3 ground_normal = character.GetGroundNormal();
                const JPH::Vec3 current_ground_velocity = character.GetGroundVelocity();
                const uint64_t ground_entity = character.GetGroundUserData();
                uint8_t ground_state = 3;
                switch (character.GetGroundState()) {
                case JPH::CharacterBase::EGroundState::OnGround: ground_state = 0; break;
                case JPH::CharacterBase::EGroundState::OnSteepGround: ground_state = 1; break;
                case JPH::CharacterBase::EGroundState::NotSupported: ground_state = 2; break;
                case JPH::CharacterBase::EGroundState::InAir: ground_state = 3; break;
                }
                out_states[written++] = GuavaJoltCharacterState{
                    entity,
                    static_cast<float>(position.GetX()),
                    static_cast<float>(position.GetY()),
                    static_cast<float>(position.GetZ()),
                    rotation.GetX(), rotation.GetY(), rotation.GetZ(), rotation.GetW(),
                    current_velocity.GetX(), current_velocity.GetY(), current_velocity.GetZ(),
                    ground_normal.GetX(), ground_normal.GetY(), ground_normal.GetZ(),
                    current_ground_velocity.GetX(), current_ground_velocity.GetY(), current_ground_velocity.GetZ(),
                    ground_entity,
                    ground_entity != 0 ? uint8_t(1) : uint8_t(0),
                    ground_state,
                    native.stance,
                    0
                };
            }
        }
        return written;
    }

	    bool raycast(const GuavaJoltRaycastQuery* query,
	                 const GuavaJoltQueryFilter* filter,
	                 GuavaJoltRaycastHit* out_hit) const {
	        if (!query || !out_hit) return false;
	        JPH::Vec3 direction(query->direction_x, query->direction_y, query->direction_z);
	        const float direction_length = direction.Length();
	        const float max_distance = std::max(query->max_distance, 0.0f);
	        if (direction_length <= 1.0e-6f || max_distance <= 0.0f) return false;
	        direction = direction / direction_length * max_distance;

	        JPH::RRayCast ray(
	            JPH::RVec3(query->origin_x, query->origin_y, query->origin_z),
	            direction);
	        MetadataBodyFilter body_filter(body_metadata, filter);
	        JPH::RayCastResult hit;
	        if (!physics_system.GetNarrowPhaseQuery().CastRay(ray, hit, {}, {}, body_filter)) {
	            return false;
	        }

	        JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), hit.mBodyID);
	        if (!lock.Succeeded()) return false;
	        const JPH::Body& body = lock.GetBody();
	        const uint64_t entity = body.GetUserData();
	        auto metadata_it = body_metadata.find(entity);
	        if (metadata_it == body_metadata.end()) return false;

	        JPH::RVec3 position = ray.GetPointOnRay(hit.mFraction);
	        JPH::Vec3 normal = body.GetWorldSpaceSurfaceNormal(hit.mSubShapeID2, position);
	        const JPH::AABox& bounds = body.GetWorldSpaceBounds();

	        out_hit->entity_id = entity;
	        out_hit->distance = hit.mFraction * max_distance;
	        out_hit->position_x = position.GetX();
	        out_hit->position_y = position.GetY();
	        out_hit->position_z = position.GetZ();
	        out_hit->normal_x = normal.GetX();
	        out_hit->normal_y = normal.GetY();
	        out_hit->normal_z = normal.GetZ();
	        fill_bounds(bounds,
	                    out_hit->bounds_min_x, out_hit->bounds_min_y, out_hit->bounds_min_z,
	                    out_hit->bounds_max_x, out_hit->bounds_max_y, out_hit->bounds_max_z);
	        out_hit->sub_shape_id = hit.mSubShapeID2.GetValue();
	        out_hit->is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
	        out_hit->reserved0 = 0;
	        out_hit->reserved1 = 0;
	        return true;
	    }

        uint32_t raycast_all(const GuavaJoltRaycastQuery* query,
                             const GuavaJoltQueryFilter* filter,
                             GuavaJoltRaycastHit* out_hits,
                             size_t hit_capacity) const {
            if (!query) return 0;
            JPH::Vec3 direction(query->direction_x, query->direction_y, query->direction_z);
            const float direction_length = direction.Length();
            const float max_distance = std::max(query->max_distance, 0.0f);
            if (direction_length <= 1.0e-6f || max_distance <= 0.0f) return 0;
            direction = direction / direction_length * max_distance;
            JPH::RRayCast ray(JPH::RVec3(query->origin_x, query->origin_y, query->origin_z), direction);
            MetadataBodyFilter body_filter(body_metadata, filter);
            JPH::AllHitCollisionCollector<JPH::CastRayCollector> collector;
            physics_system.GetNarrowPhaseQuery().CastRay(ray, {}, collector, {}, {}, body_filter);

            std::vector<GuavaJoltRaycastHit> hits;
            hits.reserve(collector.mHits.size());
            for (const JPH::RayCastResult& result : collector.mHits) {
                JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID);
                if (!lock.Succeeded()) continue;
                const JPH::Body& body = lock.GetBody();
                const uint64_t entity = body.GetUserData();
                auto metadata_it = body_metadata.find(entity);
                if (metadata_it == body_metadata.end()) continue;
                const JPH::RVec3 position = ray.GetPointOnRay(result.mFraction);
                const JPH::Vec3 normal = body.GetWorldSpaceSurfaceNormal(result.mSubShapeID2, position);
                GuavaJoltRaycastHit hit {};
                hit.entity_id = entity;
                hit.distance = result.mFraction * max_distance;
                hit.position_x = position.GetX(); hit.position_y = position.GetY(); hit.position_z = position.GetZ();
                hit.normal_x = normal.GetX(); hit.normal_y = normal.GetY(); hit.normal_z = normal.GetZ();
                fill_bounds(body.GetWorldSpaceBounds(),
                    hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
                    hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
                hit.sub_shape_id = result.mSubShapeID2.GetValue();
                hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
                hits.push_back(hit);
            }
            std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
                if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
                if (lhs.entity_id != rhs.entity_id) return lhs.entity_id < rhs.entity_id;
                return lhs.sub_shape_id < rhs.sub_shape_id;
            });
            const size_t count = std::min(hit_capacity, hits.size());
            if (out_hits) for (size_t index = 0; index < count; ++index) out_hits[index] = hits[index];
            return static_cast<uint32_t>(hits.size());
        }

	    uint32_t overlap_aabb(const GuavaJoltOverlapAABBQuery* query,
	                          const GuavaJoltQueryFilter* filter,
	                          GuavaJoltOverlapHit* out_hits,
	                          size_t hit_capacity) const {
	        if (!query) return 0;
	        JPH::AABox query_bounds = make_aabb(query->bounds_min_x, query->bounds_min_y, query->bounds_min_z,
	                                            query->bounds_max_x, query->bounds_max_y, query->bounds_max_z);
	        if (!query_bounds.IsValid()) return 0;
	        const JPH::Vec3 half_extents = (query_bounds.mMax - query_bounds.mMin) * 0.5f;
	        if (half_extents.GetX() < 0.0f || half_extents.GetY() < 0.0f || half_extents.GetZ() < 0.0f) {
	            return 0;
	        }

	        JPH::BoxShapeSettings box_settings(half_extents);
	        box_settings.SetEmbedded();
	        JPH::ShapeSettings::ShapeResult shape_result = box_settings.Create();
	        if (!shape_result.IsValid()) return 0;
	        JPH::ShapeRefC shape = shape_result.Get();

	        JPH::CollideShapeSettings collide_settings;
	        MetadataBodyFilter body_filter(body_metadata, filter);
	        JPH::ClosestHitPerBodyCollisionCollector<JPH::CollideShapeCollector> collector;
	        const JPH::Vec3 center = (query_bounds.mMin + query_bounds.mMax) * 0.5f;
	        physics_system.GetNarrowPhaseQuery().CollideShape(
	            shape,
	            JPH::Vec3::sOne(),
	            JPH::RMat44::sTranslation(JPH::RVec3(center)),
	            collide_settings,
	            JPH::RVec3::sZero(),
	            collector,
	            {},
	            {},
	            body_filter,
	            {});
	        collector.Sort();

	        std::vector<GuavaJoltOverlapHit> hits;
	        hits.reserve(collector.mHits.size());
	        for (const JPH::CollideShapeResult& result : collector.mHits) {
	            JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
	            if (!lock.Succeeded()) continue;
	            const JPH::Body& body = lock.GetBody();
	            const uint64_t entity = body.GetUserData();
	            auto metadata_it = body_metadata.find(entity);
	            if (metadata_it == body_metadata.end()) continue;

	            GuavaJoltOverlapHit hit {};
	            hit.entity_id = entity;
	            fill_bounds(body.GetWorldSpaceBounds(),
	                        hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
	                        hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
	            hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
	            hit.sub_shape_id = result.mSubShapeID2.GetValue();
	            hits.push_back(hit);
	        }

	        std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
	            return lhs.entity_id < rhs.entity_id;
	        });
	        const uint32_t max_results = query->max_results == 0 ? 0 : query->max_results;
	        if (max_results != UINT32_MAX && hits.size() > max_results) {
	            hits.resize(max_results);
	        }
	        if (out_hits && hit_capacity > 0) {
	            const size_t count = std::min(hit_capacity, hits.size());
	            for (size_t i = 0; i < count; ++i) out_hits[i] = hits[i];
	        }
	        return static_cast<uint32_t>(hits.size());
	    }

        uint32_t overlap_shape(const GuavaJoltOverlapShapeQuery* query,
                               const GuavaJoltQueryFilter* filter,
                               GuavaJoltOverlapHit* out_hits,
                               size_t hit_capacity) const {
            if (!query) return 0;
            JPH::ShapeRefC shape = build_query_shape(
                query->shape_type,
                query->box_half_extent_x,
                query->box_half_extent_y,
                query->box_half_extent_z,
                query->sphere_radius,
                query->capsule_radius,
                query->capsule_half_height);
            if (!shape) return 0;

            JPH::CollideShapeSettings collide_settings;
            MetadataBodyFilter body_filter(body_metadata, filter);
            JPH::ClosestHitPerBodyCollisionCollector<JPH::CollideShapeCollector> collector;
            physics_system.GetNarrowPhaseQuery().CollideShape(
                shape,
                JPH::Vec3::sOne(),
                query_transform(
                    query->position_x,
                    query->position_y,
                    query->position_z,
                    query->rotation_x,
                    query->rotation_y,
                    query->rotation_z,
                    query->rotation_w),
                collide_settings,
                JPH::RVec3::sZero(),
                collector,
                {},
                {},
                body_filter,
                {});
            collector.Sort();

            std::vector<GuavaJoltOverlapHit> hits;
            hits.reserve(collector.mHits.size());
            for (const JPH::CollideShapeResult& result : collector.mHits) {
                JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
                if (!lock.Succeeded()) continue;
                const JPH::Body& body = lock.GetBody();
                const uint64_t entity = body.GetUserData();
                auto metadata_it = body_metadata.find(entity);
                if (metadata_it == body_metadata.end()) continue;

                GuavaJoltOverlapHit hit {};
                hit.entity_id = entity;
                fill_bounds(body.GetWorldSpaceBounds(),
                            hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
                            hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
                hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
                hit.sub_shape_id = result.mSubShapeID2.GetValue();
                hits.push_back(hit);
            }

            std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
                return lhs.entity_id < rhs.entity_id;
            });
            const uint32_t max_results = query->max_results == 0 ? 0 : query->max_results;
            if (max_results != UINT32_MAX && hits.size() > max_results) {
                hits.resize(max_results);
            }
            if (out_hits && hit_capacity > 0) {
                const size_t count = std::min(hit_capacity, hits.size());
                for (size_t i = 0; i < count; ++i) out_hits[i] = hits[i];
            }
            return static_cast<uint32_t>(hits.size());
        }

	    bool sweep_aabb(const GuavaJoltSweepAABBQuery* query,
	                    const GuavaJoltQueryFilter* filter,
	                    GuavaJoltSweepHit* out_hit) const {
	        if (!query || !out_hit) return false;
	        JPH::AABox query_bounds = make_aabb(query->bounds_min_x, query->bounds_min_y, query->bounds_min_z,
	                                            query->bounds_max_x, query->bounds_max_y, query->bounds_max_z);
	        if (!query_bounds.IsValid()) return false;

	        JPH::Vec3 translation(query->translation_x, query->translation_y, query->translation_z);
	        const float travel_distance = translation.Length();
	        if (travel_distance <= 1.0e-6f) return false;

	        JPH::BoxShapeSettings box_settings((query_bounds.mMax - query_bounds.mMin) * 0.5f);
	        box_settings.SetEmbedded();
	        JPH::ShapeSettings::ShapeResult shape_result = box_settings.Create();
	        if (!shape_result.IsValid()) return false;
	        JPH::ShapeRefC shape = shape_result.Get();

	        const JPH::Vec3 center = (query_bounds.mMin + query_bounds.mMax) * 0.5f;
	        JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
	            shape,
	            JPH::Vec3::sOne(),
	            JPH::RMat44::sTranslation(JPH::RVec3(center)),
	            translation);
	        JPH::ShapeCastSettings settings;
	        settings.mReturnDeepestPoint = true;
	        MetadataBodyFilter body_filter(body_metadata, filter);
	        JPH::ClosestHitCollisionCollector<JPH::CastShapeCollector> collector;
	        physics_system.GetNarrowPhaseQuery().CastShape(
	            shape_cast,
	            settings,
	            JPH::RVec3(center),
	            collector,
	            {},
	            {},
	            body_filter,
	            {});
	        if (!collector.HadHit()) return false;

	        const JPH::ShapeCastResult& result = collector.mHit;
	        JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
	        if (!lock.Succeeded()) return false;
	        const JPH::Body& body = lock.GetBody();
	        const uint64_t entity = body.GetUserData();
	        auto metadata_it = body_metadata.find(entity);
	        if (metadata_it == body_metadata.end()) return false;

	        JPH::Vec3 normal = safe_normalized(-result.mPenetrationAxis, -translation / travel_distance);
	        JPH::Vec3 hit_position = center + translation * result.mFraction;
	        out_hit->entity_id = entity;
	        out_hit->fraction = result.mFraction;
	        out_hit->distance = result.mFraction * travel_distance;
	        out_hit->position_x = hit_position.GetX();
	        out_hit->position_y = hit_position.GetY();
	        out_hit->position_z = hit_position.GetZ();
	        out_hit->normal_x = normal.GetX();
	        out_hit->normal_y = normal.GetY();
	        out_hit->normal_z = normal.GetZ();
	        fill_bounds(body.GetWorldSpaceBounds(),
	                    out_hit->bounds_min_x, out_hit->bounds_min_y, out_hit->bounds_min_z,
	                    out_hit->bounds_max_x, out_hit->bounds_max_y, out_hit->bounds_max_z);
	        out_hit->sub_shape_id = result.mSubShapeID2.GetValue();
	        out_hit->is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
	        out_hit->reserved0 = 0;
	        out_hit->reserved1 = 0;
	        return true;
	    }

        bool sweep_shape(const GuavaJoltSweepShapeQuery* query,
                         const GuavaJoltQueryFilter* filter,
                         GuavaJoltSweepHit* out_hit) const {
            if (!query || !out_hit) return false;
            JPH::ShapeRefC shape = build_query_shape(
                query->shape_type,
                query->box_half_extent_x,
                query->box_half_extent_y,
                query->box_half_extent_z,
                query->sphere_radius,
                query->capsule_radius,
                query->capsule_half_height);
            if (!shape) return false;

            JPH::Vec3 translation(query->translation_x, query->translation_y, query->translation_z);
            const float travel_distance = translation.Length();
            if (travel_distance <= 1.0e-6f) return false;

            const JPH::RVec3 position(query->position_x, query->position_y, query->position_z);
            JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
                shape,
                JPH::Vec3::sOne(),
                query_transform(
                    query->position_x,
                    query->position_y,
                    query->position_z,
                    query->rotation_x,
                    query->rotation_y,
                    query->rotation_z,
                    query->rotation_w),
                translation);
            JPH::ShapeCastSettings settings;
            settings.mReturnDeepestPoint = true;
            MetadataBodyFilter body_filter(body_metadata, filter);
            JPH::ClosestHitCollisionCollector<JPH::CastShapeCollector> collector;
            physics_system.GetNarrowPhaseQuery().CastShape(
                shape_cast,
                settings,
                position,
                collector,
                {},
                {},
                body_filter,
                {});
            if (!collector.HadHit()) return false;

            const JPH::ShapeCastResult& result = collector.mHit;
            JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
            if (!lock.Succeeded()) return false;
            const JPH::Body& body = lock.GetBody();
            const uint64_t entity = body.GetUserData();
            auto metadata_it = body_metadata.find(entity);
            if (metadata_it == body_metadata.end()) return false;

            JPH::Vec3 normal = safe_normalized(-result.mPenetrationAxis, -translation / travel_distance);
            JPH::RVec3 hit_position = position + translation * result.mFraction;
            out_hit->entity_id = entity;
            out_hit->fraction = result.mFraction;
            out_hit->distance = result.mFraction * travel_distance;
            out_hit->position_x = hit_position.GetX();
            out_hit->position_y = hit_position.GetY();
            out_hit->position_z = hit_position.GetZ();
            out_hit->normal_x = normal.GetX();
            out_hit->normal_y = normal.GetY();
            out_hit->normal_z = normal.GetZ();
            fill_bounds(body.GetWorldSpaceBounds(),
                        out_hit->bounds_min_x, out_hit->bounds_min_y, out_hit->bounds_min_z,
                        out_hit->bounds_max_x, out_hit->bounds_max_y, out_hit->bounds_max_z);
            out_hit->sub_shape_id = result.mSubShapeID2.GetValue();
            out_hit->is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
            out_hit->reserved0 = 0;
            out_hit->reserved1 = 0;
            return true;
        }

        uint32_t sweep_shape_all(const GuavaJoltSweepShapeQuery* query,
                                 const GuavaJoltQueryFilter* filter,
                                 GuavaJoltSweepHit* out_hits,
                                 size_t hit_capacity) const {
            if (!query) return 0;
            JPH::ShapeRefC shape = build_query_shape(
                query->shape_type,
                query->box_half_extent_x, query->box_half_extent_y, query->box_half_extent_z,
                query->sphere_radius, query->capsule_radius, query->capsule_half_height);
            if (!shape) return 0;
            const JPH::Vec3 translation(query->translation_x, query->translation_y, query->translation_z);
            const float travel_distance = translation.Length();
            if (travel_distance <= 1.0e-6f) return 0;
            const JPH::RMat44 transform = query_transform(
                query->position_x, query->position_y, query->position_z,
                query->rotation_x, query->rotation_y, query->rotation_z, query->rotation_w);
            JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
                shape, JPH::Vec3::sOne(), transform, translation);
            JPH::ShapeCastSettings settings;
            settings.mReturnDeepestPoint = true;
            MetadataBodyFilter body_filter(body_metadata, filter);
            JPH::AllHitCollisionCollector<JPH::CastShapeCollector> collector;
            physics_system.GetNarrowPhaseQuery().CastShape(
                shape_cast, settings,
                JPH::RVec3(query->position_x, query->position_y, query->position_z),
                collector, {}, {}, body_filter, {});

            std::vector<GuavaJoltSweepHit> hits;
            hits.reserve(collector.mHits.size());
            for (const JPH::ShapeCastResult& result : collector.mHits) {
                JPH::BodyLockRead lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
                if (!lock.Succeeded()) continue;
                const JPH::Body& body = lock.GetBody();
                const uint64_t entity = body.GetUserData();
                auto metadata_it = body_metadata.find(entity);
                if (metadata_it == body_metadata.end()) continue;
                const JPH::Vec3 normal = safe_normalized(-result.mPenetrationAxis, -translation / travel_distance);
                const JPH::Vec3 position = JPH::Vec3(query->position_x, query->position_y, query->position_z)
                    + translation * result.mFraction;
                GuavaJoltSweepHit hit {};
                hit.entity_id = entity;
                hit.fraction = result.mFraction;
                hit.distance = result.mFraction * travel_distance;
                hit.position_x = position.GetX(); hit.position_y = position.GetY(); hit.position_z = position.GetZ();
                hit.normal_x = normal.GetX(); hit.normal_y = normal.GetY(); hit.normal_z = normal.GetZ();
                fill_bounds(body.GetWorldSpaceBounds(),
                    hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z,
                    hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z);
                hit.sub_shape_id = result.mSubShapeID2.GetValue();
                hit.is_trigger = metadata_it->second.is_trigger ? 1u : 0u;
                hits.push_back(hit);
            }
            std::sort(hits.begin(), hits.end(), [](const auto& lhs, const auto& rhs) {
                if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
                if (lhs.entity_id != rhs.entity_id) return lhs.entity_id < rhs.entity_id;
                return lhs.sub_shape_id < rhs.sub_shape_id;
            });
            const size_t count = std::min(hit_capacity, hits.size());
            if (out_hits) for (size_t index = 0; index < count; ++index) out_hits[index] = hits[index];
            return static_cast<uint32_t>(hits.size());
        }

	    uint32_t detect_triggers(GuavaJoltTriggerEvent* out_events, size_t event_capacity) {
	        std::unordered_set<TriggerPair, TriggerPairHash> current_pairs;

	        for (const auto& kv : body_metadata) {
	            const uint64_t trigger_entity = kv.first;
	            const BodyMetadata& trigger_metadata = kv.second;
	            if (!trigger_metadata.is_trigger) continue;
	            auto body_it = body_ids.find(trigger_entity);
	            if (body_it == body_ids.end()) continue;

	            JPH::BodyLockRead trigger_lock(physics_system.GetBodyLockInterface(), body_it->second);
	            if (!trigger_lock.Succeeded()) continue;
	            const JPH::Body& trigger_body = trigger_lock.GetBody();
	            TriggerBodyFilter body_filter(body_metadata, trigger_entity, trigger_metadata);
	            JPH::CollideShapeSettings settings;
	            JPH::ClosestHitPerBodyCollisionCollector<JPH::CollideShapeCollector> collector;
	            physics_system.GetNarrowPhaseQuery().CollideShape(
	                trigger_body.GetShape(),
	                JPH::Vec3::sOne(),
	                trigger_body.GetCenterOfMassTransform(),
	                settings,
	                JPH::RVec3::sZero(),
	                collector,
	                {},
	                {},
	                body_filter,
	                {});
	            trigger_lock.ReleaseLock();
	            collector.Sort();

	            for (const JPH::CollideShapeResult& result : collector.mHits) {
	                JPH::BodyLockRead other_lock(physics_system.GetBodyLockInterface(), result.mBodyID2);
	                if (!other_lock.Succeeded()) continue;
	                const uint64_t other_entity = other_lock.GetBody().GetUserData();
	                if (other_entity == trigger_entity) continue;
	                current_pairs.insert(TriggerPair{ trigger_entity, other_entity });
	            }
	        }

	        std::vector<GuavaJoltTriggerEvent> events;
	        events.reserve(current_pairs.size() + previous_trigger_pairs.size());
	        for (const TriggerPair& pair : current_pairs) {
	            if (previous_trigger_pairs.find(pair) == previous_trigger_pairs.end()) {
	                events.push_back(GuavaJoltTriggerEvent{ pair.trigger, pair.other, kTriggerEnter, 0, 0 });
	            }
	        }
	        for (const TriggerPair& pair : previous_trigger_pairs) {
	            if (current_pairs.find(pair) == current_pairs.end()) {
	                events.push_back(GuavaJoltTriggerEvent{ pair.trigger, pair.other, kTriggerExit, 0, 0 });
	            }
	        }
	        for (const TriggerPair& pair : current_pairs) {
	            events.push_back(GuavaJoltTriggerEvent{ pair.trigger, pair.other, kTriggerActive, 0, 0 });
	        }
	        std::sort(events.begin(), events.end(), [](const auto& lhs, const auto& rhs) {
	            if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
	            if (lhs.trigger_entity != rhs.trigger_entity) return lhs.trigger_entity < rhs.trigger_entity;
	            return lhs.other_entity < rhs.other_entity;
	        });

	        previous_trigger_pairs = std::move(current_pairs);
	        if (out_events && event_capacity > 0) {
	            const size_t count = std::min(event_capacity, events.size());
	            for (size_t i = 0; i < count; ++i) out_events[i] = events[i];
	        }
	        return static_cast<uint32_t>(events.size());
	    }

        uint32_t copy_contact_events(GuavaJoltContactEvent* out_events, size_t event_capacity) const {
            return contact_listener.copy_events(out_events, event_capacity);
        }
	};

extern "C" {

uint32_t guava_jolt_bridge_abi_version(void) {
    return GUAVA_JOLT_ABI_VERSION;
}

bool guava_jolt_bridge_get_abi_layout(GuavaJoltABILayout* out_layout) {
    if (!out_layout) return false;
    out_layout->abi_version = GUAVA_JOLT_ABI_VERSION;
    out_layout->struct_size = static_cast<uint32_t>(sizeof(GuavaJoltABILayout));
    out_layout->body_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltBodyDesc));
    out_layout->constraint_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltConstraintDesc));
    out_layout->step_config_size = static_cast<uint32_t>(sizeof(GuavaJoltStepConfig));
    out_layout->body_state_size = static_cast<uint32_t>(sizeof(GuavaJoltBodyState));
    out_layout->contact_event_size = static_cast<uint32_t>(sizeof(GuavaJoltContactEvent));
    out_layout->character_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltCharacterDesc));
    out_layout->character_command_size = static_cast<uint32_t>(sizeof(GuavaJoltCharacterCommand));
    out_layout->character_state_size = static_cast<uint32_t>(sizeof(GuavaJoltCharacterState));
    out_layout->shape_instance_size = static_cast<uint32_t>(sizeof(GuavaJoltShapeInstance));
    return true;
}

GuavaJoltContext guava_jolt_context_create(void) {
    ensure_jolt_initialized();
    return new (std::nothrow) GuavaJoltContextImpl();
}

uint32_t guava_jolt_context_last_error(GuavaJoltContext context) {
    return context ? context->last_error : GUAVA_JOLT_ERROR_INVALID_ARGUMENT;
}

void guava_jolt_context_destroy(GuavaJoltContext context) {
    delete context;
}

void guava_jolt_context_reset(GuavaJoltContext context) {
    if (!context) return;
    context->clear_all();
}

bool guava_jolt_context_prepare(GuavaJoltContext context,
                                const GuavaJoltBodyDesc* bodies, size_t body_count,
                                const GuavaJoltConstraintDesc* constraints,
                                size_t constraint_count,
                                GuavaJoltPrepareStats* out_stats) {
    if (!context || !out_stats) return false;
    return context->prepare(bodies, body_count, constraints, constraint_count,
                            nullptr, 0, out_stats);
}

bool guava_jolt_context_prepare_with_meshes(GuavaJoltContext context,
                                            const GuavaJoltBodyDesc* bodies, size_t body_count,
                                            const GuavaJoltConstraintDesc* constraints,
                                            size_t constraint_count,
                                            const GuavaJoltMeshGeometry* meshes, size_t mesh_count,
                                            GuavaJoltPrepareStats* out_stats) {
    if (!context || !out_stats) return false;
    return context->prepare(bodies, body_count, constraints, constraint_count,
                            meshes, mesh_count, out_stats);
}

bool guava_jolt_context_step(GuavaJoltContext context, const GuavaJoltStepConfig* config,
                             GuavaJoltBodyState* states, size_t state_count,
                             GuavaJoltStepStats* out_stats) {
    if (!context) return false;
    if (state_count > 0 && !states) return false;
    return context->step(config, states, state_count, out_stats);
}

bool guava_jolt_context_sync_characters(GuavaJoltContext context,
                                        const GuavaJoltCharacterDesc* characters,
                                        size_t character_count) {
    if (!context) return false;
    return context->sync_characters(characters, character_count);
}

uint32_t guava_jolt_context_step_characters(GuavaJoltContext context,
                                            const GuavaJoltStepConfig* config,
                                            const GuavaJoltCharacterCommand* commands,
                                            size_t command_count,
                                            GuavaJoltCharacterState* out_states,
                                            size_t state_capacity) {
    if (!context) return 0;
    return context->step_characters(
        config, commands, command_count, out_states, state_capacity);
}

bool guava_jolt_context_raycast(GuavaJoltContext context,
                                const GuavaJoltRaycastQuery* query,
                                const GuavaJoltQueryFilter* filter,
                                GuavaJoltRaycastHit* out_hit) {
    if (!context) return false;
    return context->raycast(query, filter, out_hit);
}

uint32_t guava_jolt_context_raycast_all(GuavaJoltContext context,
                                        const GuavaJoltRaycastQuery* query,
                                        const GuavaJoltQueryFilter* filter,
                                        GuavaJoltRaycastHit* out_hits,
                                        size_t hit_capacity) {
    if (!context || (hit_capacity > 0 && !out_hits)) return 0;
    return context->raycast_all(query, filter, out_hits, hit_capacity);
}

uint32_t guava_jolt_context_overlap_aabb(GuavaJoltContext context,
                                         const GuavaJoltOverlapAABBQuery* query,
                                         const GuavaJoltQueryFilter* filter,
                                         GuavaJoltOverlapHit* out_hits,
                                         size_t hit_capacity) {
    if (!context) return 0;
    if (hit_capacity > 0 && !out_hits) return 0;
    return context->overlap_aabb(query, filter, out_hits, hit_capacity);
}

uint32_t guava_jolt_context_overlap_shape(GuavaJoltContext context,
                                          const GuavaJoltOverlapShapeQuery* query,
                                          const GuavaJoltQueryFilter* filter,
                                          GuavaJoltOverlapHit* out_hits,
                                          size_t hit_capacity) {
    if (!context) return 0;
    if (hit_capacity > 0 && !out_hits) return 0;
    return context->overlap_shape(query, filter, out_hits, hit_capacity);
}

bool guava_jolt_context_sweep_aabb(GuavaJoltContext context,
                                   const GuavaJoltSweepAABBQuery* query,
                                   const GuavaJoltQueryFilter* filter,
                                   GuavaJoltSweepHit* out_hit) {
    if (!context) return false;
    return context->sweep_aabb(query, filter, out_hit);
}

bool guava_jolt_context_sweep_shape(GuavaJoltContext context,
                                    const GuavaJoltSweepShapeQuery* query,
                                    const GuavaJoltQueryFilter* filter,
                                    GuavaJoltSweepHit* out_hit) {
    if (!context) return false;
    return context->sweep_shape(query, filter, out_hit);
}

uint32_t guava_jolt_context_sweep_shape_all(GuavaJoltContext context,
                                            const GuavaJoltSweepShapeQuery* query,
                                            const GuavaJoltQueryFilter* filter,
                                            GuavaJoltSweepHit* out_hits,
                                            size_t hit_capacity) {
    if (!context || (hit_capacity > 0 && !out_hits)) return 0;
    return context->sweep_shape_all(query, filter, out_hits, hit_capacity);
}

uint32_t guava_jolt_context_detect_triggers(GuavaJoltContext context,
                                            GuavaJoltTriggerEvent* out_events,
                                            size_t event_capacity) {
    if (!context) return 0;
    if (event_capacity > 0 && !out_events) return 0;
    return context->detect_triggers(out_events, event_capacity);
}

uint32_t guava_jolt_context_copy_contact_events(GuavaJoltContext context,
                                                GuavaJoltContactEvent* out_events,
                                                size_t event_capacity) {
    if (!context) return 0;
    if (event_capacity > 0 && !out_events) return 0;
    return context->copy_contact_events(out_events, event_capacity);
}

}  // extern "C"
