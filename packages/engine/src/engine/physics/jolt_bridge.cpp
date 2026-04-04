#include <Jolt/Jolt.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/Body.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/CollideShape.h>
#include <Jolt/Physics/Collision/ShapeCast.h>
#include <Jolt/Physics/Collision/CollisionCollectorImpl.h>
#include <Jolt/Physics/Collision/ContactListener.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/StaticCompoundShape.h>
#include <Jolt/Physics/Constraints/PointConstraint.h>
#include <Jolt/Physics/Constraints/HingeConstraint.h>
#include <Jolt/Physics/Constraints/SliderConstraint.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <new>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

struct GuavaJoltBodyDesc;
struct GuavaJoltStepConfig;
struct GuavaJoltBodyState;
struct GuavaJoltStepStats;
struct GuavaJoltContext;
struct GuavaJoltQueryFilter;

namespace {
constexpr uint32_t kFlagHasBox = 1u << 0;
constexpr uint32_t kFlagHasSphere = 1u << 1;
constexpr uint32_t kFlagHasMeshProxy = 1u << 2;
constexpr uint32_t kFlagBodyIsSensor = 1u << 3;
constexpr uint32_t kFlagAllowSleep = 1u << 4;

namespace Layers {
static constexpr JPH::ObjectLayer NON_MOVING = 0;
static constexpr JPH::ObjectLayer MOVING = 1;
static constexpr JPH::ObjectLayer NUM_LAYERS = 2;
} // namespace Layers

namespace BroadPhaseLayers {
static constexpr JPH::BroadPhaseLayer NON_MOVING(0);
static constexpr JPH::BroadPhaseLayer MOVING(1);
static constexpr uint NUM_LAYERS = 2;
} // namespace BroadPhaseLayers

class BroadPhaseLayerInterfaceImpl final
    : public JPH::BroadPhaseLayerInterface {
public:
  BroadPhaseLayerInterfaceImpl() {
    m_object_to_broad_phase[Layers::NON_MOVING] = BroadPhaseLayers::NON_MOVING;
    m_object_to_broad_phase[Layers::MOVING] = BroadPhaseLayers::MOVING;
  }

  uint GetNumBroadPhaseLayers() const override {
    return BroadPhaseLayers::NUM_LAYERS;
  }

  JPH::BroadPhaseLayer
  GetBroadPhaseLayer(JPH::ObjectLayer in_layer) const override {
    return m_object_to_broad_phase[in_layer];
  }

#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
  const char *
  GetBroadPhaseLayerName(JPH::BroadPhaseLayer in_layer) const override {
    switch (static_cast<JPH::BroadPhaseLayer::Type>(in_layer)) {
    case static_cast<JPH::BroadPhaseLayer::Type>(BroadPhaseLayers::NON_MOVING):
      return "NON_MOVING";
    case static_cast<JPH::BroadPhaseLayer::Type>(BroadPhaseLayers::MOVING):
      return "MOVING";
    default:
      return "INVALID";
    }
  }
#endif

private:
  std::array<JPH::BroadPhaseLayer, Layers::NUM_LAYERS>
      m_object_to_broad_phase{};
};

class ObjectVsBroadPhaseLayerFilterImpl final
    : public JPH::ObjectVsBroadPhaseLayerFilter {
public:
  bool ShouldCollide(JPH::ObjectLayer in_layer1,
                     JPH::BroadPhaseLayer in_layer2) const override {
    switch (in_layer1) {
    case Layers::NON_MOVING:
      return in_layer2 == BroadPhaseLayers::MOVING;
    case Layers::MOVING:
      return true;
    default:
      return false;
    }
  }
};

class ObjectLayerPairFilterImpl final : public JPH::ObjectLayerPairFilter {
public:
  bool ShouldCollide(JPH::ObjectLayer in_object1,
                     JPH::ObjectLayer in_object2) const override {
    switch (in_object1) {
    case Layers::NON_MOVING:
      return in_object2 == Layers::MOVING;
    case Layers::MOVING:
      return true;
    default:
      return false;
    }
  }
};

struct GuavaTriggerEvent {
  uint64_t entity_a;
  uint64_t entity_b;
  uint8_t kind;
};

extern "C" void GuavaJoltEnqueueTriggerEvent(const GuavaTriggerEvent *event);
extern "C" void GuavaJoltEnqueueCollisionEvent(const GuavaTriggerEvent *event);

class GuavaContactListener final : public JPH::ContactListener {
public:
  void SetPhysicsSystem(JPH::PhysicsSystem *in_system) { physics_system = in_system; }

  void OnContactAdded(const JPH::Body &body1, const JPH::Body &body2,
                      const JPH::ContactManifold &,
                      JPH::ContactSettings &) override {
    ++m_contact_count;

    const bool is_sensor1 = body1.IsSensor();
    const bool is_sensor2 = body2.IsSensor();

    if (is_sensor1 || is_sensor2) {
      GuavaTriggerEvent event{};
      event.entity_a = body1.GetUserData();
      event.entity_b = body2.GetUserData();
      event.kind = 0;
      GuavaJoltEnqueueTriggerEvent(&event);
    } else {
      GuavaTriggerEvent event{};
      event.entity_a = body1.GetUserData();
      event.entity_b = body2.GetUserData();
      event.kind = 0; // enter
      GuavaJoltEnqueueCollisionEvent(&event);
    }
  }

  void OnContactPersisted(const JPH::Body &body1, const JPH::Body &body2,
                          const JPH::ContactManifold &,
                          JPH::ContactSettings &) override {
    const bool is_sensor1 = body1.IsSensor();
    const bool is_sensor2 = body2.IsSensor();

    if (is_sensor1 || is_sensor2) {
      GuavaTriggerEvent event{};
      event.entity_a = body1.GetUserData();
      event.entity_b = body2.GetUserData();
      event.kind = 1;
      GuavaJoltEnqueueTriggerEvent(&event);
    }
  }

  void OnContactRemoved(const JPH::SubShapeIDPair &pair) override {
    GuavaTriggerEvent event{};
    bool is_sensor = false;
    if (physics_system != nullptr) {
      const JPH::Body *body1 = physics_system->GetBodyLockInterface().TryGetBody(pair.GetBody1ID());
      const JPH::Body *body2 = physics_system->GetBodyLockInterface().TryGetBody(pair.GetBody2ID());
      event.entity_a = body1 ? body1->GetUserData() : 0;
      event.entity_b = body2 ? body2->GetUserData() : 0;
      is_sensor = (body1 && body1->IsSensor()) || (body2 && body2->IsSensor());
    } else {
      event.entity_a = 0;
      event.entity_b = 0;
    }
    event.kind = 2; // exit
    if (is_sensor) {
      GuavaJoltEnqueueTriggerEvent(&event);
    } else {
      event.kind = 1; // collision exit
      GuavaJoltEnqueueCollisionEvent(&event);
    }
  }

  void Reset() { m_contact_count = 0; }

  uint32_t GetCount() const { return m_contact_count; }

private:
  uint32_t m_contact_count = 0;
  JPH::PhysicsSystem *physics_system = nullptr;
};

struct Globals {
  Globals() {
    JPH::RegisterDefaultAllocator();
    JPH::Factory::sInstance = new JPH::Factory();
    JPH::RegisterTypes();
  }

  ~Globals() {
    JPH::UnregisterTypes();
    delete JPH::Factory::sInstance;
    JPH::Factory::sInstance = nullptr;
  }
};

void EnsureInitialized() {
  static std::once_flag once;
  std::call_once(once, []() {
    static Globals globals;
    (void)globals;
  });
}

JPH::Vec3 ToVec3(const float in_value[3]) {
  return JPH::Vec3(in_value[0], in_value[1], in_value[2]);
}

JPH::RVec3 ToRVec3(const float in_value[3]) {
  return JPH::RVec3(in_value[0], in_value[1], in_value[2]);
}

JPH::Quat ToQuat(const float in_value[4]) {
  return JPH::Quat(in_value[0], in_value[1], in_value[2], in_value[3]);
}

void StoreVec3(JPH::Vec3Arg in_value, float out_value[3]) {
  out_value[0] = in_value.GetX();
  out_value[1] = in_value.GetY();
  out_value[2] = in_value.GetZ();
}

void StoreRVec3(JPH::RVec3Arg in_value, float out_value[3]) {
  out_value[0] = static_cast<float>(in_value.GetX());
  out_value[1] = static_cast<float>(in_value.GetY());
  out_value[2] = static_cast<float>(in_value.GetZ());
}

JPH::Vec3 ToPositiveHalfExtents(const float in_value[3]) {
  return JPH::Vec3(
      std::max(std::abs(in_value[0]), 1.0e-4f),
      std::max(std::abs(in_value[1]), 1.0e-4f),
      std::max(std::abs(in_value[2]), 1.0e-4f));
}

JPH::EMotionType ToMotionType(uint32_t in_motion_type) {
  switch (in_motion_type) {
  case 0:
    return JPH::EMotionType::Static;
  case 2:
    return JPH::EMotionType::Kinematic;
  default:
    return JPH::EMotionType::Dynamic;
  }
}

JPH::ObjectLayer ToObjectLayer(JPH::EMotionType in_motion_type) {
  return in_motion_type == JPH::EMotionType::Dynamic ? Layers::MOVING
                                                     : Layers::NON_MOVING;
}
} // namespace

extern "C" {
struct GuavaJoltBodyDesc {
  uint64_t entity_id;
  uint32_t motion_type;
  uint32_t flags;
  float mass;
  float gravity_scale;
  float linear_damping;
  float angular_damping;
  float max_linear_speed;
  float max_angular_speed;
  float position[3];
  float rotation[4];
  float linear_velocity[3];
  float angular_velocity[3];
  float box_half_extents[3];
  float box_center[3];
  float sphere_radius;
  float sphere_center[3];
  float mesh_half_extents[3];
  float mesh_center[3];
  uint16_t layer_id;
  uint16_t layer_group;
};

struct GuavaJoltConstraintDesc {
  uint64_t entity_id;
  uint8_t constraint_type;
  uint64_t entity_a;
  uint64_t entity_b;
  float pivot_a[3];
  float pivot_b[3];
  float axis_a[3];
  float axis_b[3];
  float min_limit;
  float max_limit;
  uint8_t is_enabled;
};

struct GuavaJoltStepConfig {
  float delta_seconds;
  float gravity[3];
  uint32_t collision_steps;
  uint32_t temp_allocator_size_bytes;
  uint32_t max_bodies;
  uint32_t num_body_mutexes;
  uint32_t max_body_pairs;
  uint32_t max_contact_constraints;
};

struct GuavaJoltBodyState {
  uint64_t entity_id;
  float position[3];
  float rotation[4];
  float linear_velocity[3];
  float angular_velocity[3];
};

struct GuavaJoltStepStats {
  uint32_t dynamic_bodies;
  uint32_t static_bodies;
  uint32_t contacts_resolved;
  uint32_t state_count;
  uint8_t success;
  uint8_t reserved0;
  uint16_t reserved1;
};

struct GuavaJoltQueryFilter {
  uint64_t exclude_entity;
  uint16_t layer_id;
  uint16_t layer_group_mask;
  uint8_t has_exclude_entity;
  uint8_t include_triggers;
  uint8_t has_layer_id;
  uint8_t reserved0;
};

struct GuavaJoltRayQuery {
  float origin[3];
  float direction[3];
  float max_distance;
};

struct GuavaJoltRaycastHit {
  uint64_t entity_id;
  float distance;
  float position[3];
  float normal[3];
  uint8_t is_trigger;
  uint8_t reserved0;
  uint16_t reserved1;
};

struct GuavaJoltOverlapHit {
  uint64_t entity_id;
  uint8_t is_trigger;
  uint8_t reserved0;
  uint16_t reserved1;
};

struct GuavaJoltSweepHit {
  uint64_t entity_id;
  float fraction;
  float distance;
  float position[3];
  float normal[3];
  uint8_t is_trigger;
  uint8_t reserved0;
  uint16_t reserved1;
};
}

namespace {
struct BodyRecord {
  GuavaJoltBodyDesc desc{};
  JPH::BodyID body_id{};
  JPH::Body *body_ptr = nullptr;
};

bool EqualVec3(const float lhs[3], const float rhs[3]) {
  for (int index = 0; index < 3; ++index) {
    if (lhs[index] != rhs[index]) {
      return false;
    }
  }
  return true;
}

bool EqualQuat(const float lhs[4], const float rhs[4]) {
  for (int index = 0; index < 4; ++index) {
    if (lhs[index] != rhs[index]) {
      return false;
    }
  }
  return true;
}

bool EqualShapeAndSettings(const GuavaJoltBodyDesc &lhs,
                           const GuavaJoltBodyDesc &rhs) {
  return lhs.motion_type == rhs.motion_type && lhs.flags == rhs.flags &&
         lhs.mass == rhs.mass && lhs.gravity_scale == rhs.gravity_scale &&
         lhs.linear_damping == rhs.linear_damping &&
         lhs.angular_damping == rhs.angular_damping &&
         lhs.max_linear_speed == rhs.max_linear_speed &&
         lhs.max_angular_speed == rhs.max_angular_speed &&
         lhs.sphere_radius == rhs.sphere_radius &&
         EqualVec3(lhs.box_half_extents, rhs.box_half_extents) &&
         EqualVec3(lhs.box_center, rhs.box_center) &&
         EqualVec3(lhs.sphere_center, rhs.sphere_center) &&
         EqualVec3(lhs.mesh_half_extents, rhs.mesh_half_extents) &&
         EqualVec3(lhs.mesh_center, rhs.mesh_center);
}

bool EqualPoseAndVelocity(const GuavaJoltBodyDesc &lhs,
                          const GuavaJoltBodyDesc &rhs) {
  return EqualVec3(lhs.position, rhs.position) &&
         EqualQuat(lhs.rotation, rhs.rotation) &&
         EqualVec3(lhs.linear_velocity, rhs.linear_velocity) &&
         EqualVec3(lhs.angular_velocity, rhs.angular_velocity);
}

bool BuildBodyShape(const GuavaJoltBodyDesc &desc, JPH::ShapeRefC &out_shape) {
  int shape_count = 0;
  JPH::StaticCompoundShapeSettings compound_settings;

  if ((desc.flags & kFlagHasBox) != 0) {
    const JPH::Vec3 half_extents = ToVec3(desc.box_half_extents);
    if (half_extents.ReduceMin() > 0.0f) {
      compound_settings.AddShape(ToVec3(desc.box_center),
                                 JPH::Quat::sIdentity(),
                                 new JPH::BoxShape(half_extents));
      ++shape_count;
    }
  }

  if ((desc.flags & kFlagHasSphere) != 0 && desc.sphere_radius > 0.0f) {
    compound_settings.AddShape(ToVec3(desc.sphere_center),
                               JPH::Quat::sIdentity(),
                               new JPH::SphereShape(desc.sphere_radius));
    ++shape_count;
  }

  if ((desc.flags & kFlagHasMeshProxy) != 0) {
    const JPH::Vec3 half_extents = ToVec3(desc.mesh_half_extents);
    if (half_extents.ReduceMin() > 0.0f) {
      compound_settings.AddShape(ToVec3(desc.mesh_center),
                                 JPH::Quat::sIdentity(),
                                 new JPH::BoxShape(half_extents));
      ++shape_count;
    }
  }

  if (shape_count == 0) {
    return false;
  }

  JPH::Shape::ShapeResult shape_result = compound_settings.Create();
  if (shape_result.HasError()) {
    return false;
  }

  out_shape = shape_result.Get();
  return true;
}

JPH::BodyCreationSettings
MakeBodyCreationSettings(const GuavaJoltBodyDesc &desc, JPH::ShapeRefC shape) {
  const JPH::EMotionType motion_type = ToMotionType(desc.motion_type);
  JPH::BodyCreationSettings settings(shape.GetPtr(), ToRVec3(desc.position),
                                     ToQuat(desc.rotation), motion_type,
                                     ToObjectLayer(motion_type));
  settings.mUserData = desc.entity_id;
  settings.mLinearVelocity = ToVec3(desc.linear_velocity);
  settings.mAngularVelocity = ToVec3(desc.angular_velocity);
  settings.mAllowSleeping = (desc.flags & kFlagAllowSleep) != 0;
  settings.mIsSensor = (desc.flags & kFlagBodyIsSensor) != 0;
  settings.mCollideKinematicVsNonDynamic =
      motion_type == JPH::EMotionType::Kinematic || settings.mIsSensor;
  settings.mLinearDamping = desc.linear_damping;
  settings.mAngularDamping = desc.angular_damping;
  settings.mMaxLinearVelocity = desc.max_linear_speed;
  settings.mMaxAngularVelocity = desc.max_angular_speed;
  settings.mGravityFactor = desc.gravity_scale;
  if (motion_type != JPH::EMotionType::Static) {
    settings.mOverrideMassProperties =
        JPH::EOverrideMassProperties::CalculateInertia;
    settings.mMassPropertiesOverride.mMass = std::max(desc.mass, 0.001f);
  }
  return settings;
}
} // namespace

struct GuavaJoltContext {
  explicit GuavaJoltContext(const GuavaJoltStepConfig &config) {
    physics_system.Init(
        config.max_bodies, config.num_body_mutexes, config.max_body_pairs,
        config.max_contact_constraints, broad_phase_layer_interface,
        object_vs_broad_phase_layer_filter, object_layer_pair_filter);
    physics_system.SetGravity(ToVec3(config.gravity));
    physics_system.SetContactListener(&contact_listener);
    contact_listener.SetPhysicsSystem(&physics_system);
    job_system.Init(JPH::cMaxPhysicsJobs);
  }

  ~GuavaJoltContext() { 
    ClearBodies(); 
    ClearConstraints();
  }

  void ClearBodies() {
    JPH::BodyInterface &body_interface = physics_system.GetBodyInterface();
    for (auto &entry : body_records) {
      if (body_interface.IsAdded(entry.second.body_id)) {
        body_interface.RemoveBody(entry.second.body_id);
      }
      body_interface.DestroyBody(entry.second.body_id);
    }
    body_records.clear();
  }

  void ClearConstraints() {
    for (auto &entry : constraint_records) {
      physics_system.RemoveConstraint(entry.second);
      delete entry.second;
    }
    constraint_records.clear();
  }

  JPH::BodyID GetBodyID(uint64_t entity_id) {
    auto entry = body_records.find(entity_id);
    if (entry == body_records.end()) {
      return JPH::BodyID();
    }
    return entry->second.body_id;
  }
  
  bool IsBodyValid(uint64_t entity_id) {
    auto entry = body_records.find(entity_id);
    if (entry == body_records.end()) {
      return false;
    }
    JPH::BodyInterface &body_interface = physics_system.GetBodyInterface();
    return body_interface.IsAdded(entry->second.body_id);
  }

  bool AddOrUpdateConstraint(const GuavaJoltConstraintDesc &desc) {
    JPH::BodyID body_a_id = GetBodyID(desc.entity_a);
    JPH::BodyID body_b_id = GetBodyID(desc.entity_b);
    if (body_a_id.IsInvalid() || body_b_id.IsInvalid()) {
      return false;
    }
    if (!IsBodyValid(desc.entity_a) || !IsBodyValid(desc.entity_b)) {
      return false;
    }

    auto existing = constraint_records.find(desc.entity_id);
    if (existing != constraint_records.end()) {
      physics_system.RemoveConstraint(existing->second);
      delete existing->second;
      constraint_records.erase(existing);
    }

    JPH::TwoBodyConstraint *constraint = nullptr;
    {
      const JPH::BodyLockInterface &lock_interface = physics_system.GetBodyLockInterface();
      JPH::BodyLockWrite lock_a(lock_interface, body_a_id);
      JPH::BodyLockWrite lock_b(lock_interface, body_b_id);
      if (!lock_a.Succeeded() || !lock_b.Succeeded()) {
        return false;
      }
      JPH::Body &body_a = lock_a.GetBody();
      JPH::Body &body_b = lock_b.GetBody();

      switch (desc.constraint_type) {
      case 0: {
        JPH::PointConstraintSettings settings;
        settings.mPoint1 = JPH::RVec3(desc.pivot_a[0], desc.pivot_a[1], desc.pivot_a[2]);
        settings.mPoint2 = JPH::RVec3(desc.pivot_b[0], desc.pivot_b[1], desc.pivot_b[2]);
        constraint = static_cast<JPH::TwoBodyConstraint *>(settings.Create(body_a, body_b));
        break;
      }
      case 1: {
        JPH::HingeConstraintSettings settings;
        settings.mPoint1 = JPH::RVec3(desc.pivot_a[0], desc.pivot_a[1], desc.pivot_a[2]);
        settings.mPoint2 = JPH::RVec3(desc.pivot_b[0], desc.pivot_b[1], desc.pivot_b[2]);
        settings.mHingeAxis1 = JPH::Vec3(desc.axis_a[0], desc.axis_a[1], desc.axis_a[2]);
        settings.mHingeAxis2 = JPH::Vec3(desc.axis_b[0], desc.axis_b[1], desc.axis_b[2]);
        settings.mLimitsMin = desc.min_limit;
        settings.mLimitsMax = desc.max_limit;
        constraint = static_cast<JPH::TwoBodyConstraint *>(settings.Create(body_a, body_b));
        break;
      }
      case 2: {
        JPH::SliderConstraintSettings settings;
        settings.mSpace = JPH::EConstraintSpace::WorldSpace;
        settings.mPoint1 = JPH::RVec3(desc.pivot_a[0], desc.pivot_a[1], desc.pivot_a[2]);
        settings.mPoint2 = JPH::RVec3(desc.pivot_b[0], desc.pivot_b[1], desc.pivot_b[2]);
        settings.mSliderAxis1 = JPH::Vec3(desc.axis_a[0], desc.axis_a[1], desc.axis_a[2]);
        settings.mSliderAxis2 = JPH::Vec3(desc.axis_b[0], desc.axis_b[1], desc.axis_b[2]);
        settings.mLimitsMin = desc.min_limit;
        settings.mLimitsMax = desc.max_limit;
        constraint = static_cast<JPH::TwoBodyConstraint *>(settings.Create(body_a, body_b));
        break;
      }
      case 3: {
        JPH::DistanceConstraintSettings settings;
        settings.mPoint1 = JPH::RVec3(desc.pivot_a[0], desc.pivot_a[1], desc.pivot_a[2]);
        settings.mPoint2 = JPH::RVec3(desc.pivot_b[0], desc.pivot_b[1], desc.pivot_b[2]);
        settings.mMinDistance = desc.min_limit;
        settings.mMaxDistance = desc.max_limit;
        constraint = static_cast<JPH::TwoBodyConstraint *>(settings.Create(body_a, body_b));
        break;
      }
      default:
        return false;
      }
    }

    if (!constraint) {
      return false;
    }

    constraint->SetEnabled(desc.is_enabled != 0);
    physics_system.AddConstraint(constraint);
    constraint_records.insert_or_assign(desc.entity_id, constraint);
    return true;
  }

  bool RemoveConstraint(uint64_t entity_id) {
    auto entry = constraint_records.find(entity_id);
    if (entry == constraint_records.end()) {
      return true;
    }

    physics_system.RemoveConstraint(entry->second);
    delete entry->second;
    constraint_records.erase(entry);
    return true;
  }

  bool RemoveBody(uint64_t entity_id) {
    const auto entry = body_records.find(entity_id);
    if (entry == body_records.end()) {
      return true;
    }

    JPH::BodyInterface &body_interface = physics_system.GetBodyInterface();
    if (body_interface.IsAdded(entry->second.body_id)) {
      body_interface.RemoveBody(entry->second.body_id);
    }
    body_interface.DestroyBody(entry->second.body_id);
    body_records.erase(entry);
    return true;
  }

  bool CreateBody(const GuavaJoltBodyDesc &desc) {
    JPH::ShapeRefC shape;
    if (!BuildBodyShape(desc, shape)) {
      return false;
    }

    JPH::BodyInterface &body_interface = physics_system.GetBodyInterface();
    const JPH::EMotionType motion_type = ToMotionType(desc.motion_type);
    const JPH::EActivation activation = motion_type == JPH::EMotionType::Dynamic
                                            ? JPH::EActivation::Activate
                                            : JPH::EActivation::DontActivate;
    const JPH::BodyID body_id = body_interface.CreateAndAddBody(
        MakeBodyCreationSettings(desc, shape), activation);
    if (body_id.IsInvalid()) {
      fprintf(stderr, "Jolt Error: CreateAndAddBody failed for entity %llu\\n", desc.entity_id);
      return false;
    }

    // 注意：Jolt 的 BodyInterface::TryGetBody 可能在某些版本中不可用
    // 我们存储 body_id，在 GetBody 时通过 body_lock_interface 获取
    BodyRecord record{};
    record.desc = desc;
    record.body_id = body_id;
    // body_ptr 会在 GetBody 时动态获取
    body_records.insert_or_assign(desc.entity_id, record);
    return true;
  }

  bool SyncExistingBody(const GuavaJoltBodyDesc &desc, float delta_seconds) {
    auto entry = body_records.find(desc.entity_id);
    if (entry == body_records.end()) {
      return CreateBody(desc);
    }

    if (!EqualShapeAndSettings(entry->second.desc, desc)) {
      if (!RemoveBody(desc.entity_id)) {
        return false;
      }
      return CreateBody(desc);
    }

    if (!EqualPoseAndVelocity(entry->second.desc, desc)) {
      JPH::BodyInterface &body_interface = physics_system.GetBodyInterface();
      const JPH::EMotionType motion_type = ToMotionType(desc.motion_type);
      switch (motion_type) {
      case JPH::EMotionType::Static:
        body_interface.SetPositionAndRotationWhenChanged(
            entry->second.body_id, ToRVec3(desc.position),
            ToQuat(desc.rotation), JPH::EActivation::DontActivate);
        break;
      case JPH::EMotionType::Kinematic:
        body_interface.MoveKinematic(
            entry->second.body_id, ToRVec3(desc.position),
            ToQuat(desc.rotation), std::max(delta_seconds, 1.0e-5f));
        break;
      case JPH::EMotionType::Dynamic:
        body_interface.SetPositionRotationAndVelocity(
            entry->second.body_id, ToRVec3(desc.position),
            ToQuat(desc.rotation), ToVec3(desc.linear_velocity),
            ToVec3(desc.angular_velocity));
        break;
      }
    }

    entry->second.desc = desc;
    return true;
  }

  bool SyncBodiesSnapshot(const GuavaJoltBodyDesc *in_bodies, size_t in_body_count,
                          float delta_seconds) {
    std::unordered_set<uint64_t> seen_entities;
    seen_entities.reserve(in_body_count);

    for (size_t index = 0; index < in_body_count; ++index) {
      const GuavaJoltBodyDesc &desc = in_bodies[index];
      seen_entities.insert(desc.entity_id);

      JPH::ShapeRefC shape;
      if (!BuildBodyShape(desc, shape)) {
        if (!RemoveBody(desc.entity_id)) {
          return false;
        }
        continue;
      }

      if (!SyncExistingBody(desc, delta_seconds)) {
        return false;
      }
    }

    std::vector<uint64_t> stale_entities;
    stale_entities.reserve(body_records.size());
    for (const auto &entry : body_records) {
      if (seen_entities.find(entry.first) == seen_entities.end()) {
        stale_entities.push_back(entry.first);
      }
    }

    for (uint64_t entity_id : stale_entities) {
      if (!RemoveBody(entity_id)) {
        return false;
      }
    }

    return true;
  }

  BroadPhaseLayerInterfaceImpl broad_phase_layer_interface{};
  ObjectVsBroadPhaseLayerFilterImpl object_vs_broad_phase_layer_filter{};
  ObjectLayerPairFilterImpl object_layer_pair_filter{};
  GuavaContactListener contact_listener{};
  JPH::PhysicsSystem physics_system{};
  JPH::JobSystemSingleThreaded job_system{};
  std::unordered_map<uint64_t, BodyRecord> body_records{};
  std::unordered_map<uint64_t, JPH::TwoBodyConstraint *> constraint_records{};
};

class QueryBodyFilter final : public JPH::BodyFilter {
public:
  QueryBodyFilter(const GuavaJoltContext &in_context,
                  const GuavaJoltQueryFilter &in_filter)
      : context(in_context), filter(in_filter) {}

  bool ShouldCollideLocked(const JPH::Body &in_body) const override {
    const uint64_t entity_id = in_body.GetUserData();
    if (filter.has_exclude_entity != 0 && entity_id == filter.exclude_entity) {
      return false;
    }

    const auto entry = context.body_records.find(entity_id);
    if (entry == context.body_records.end()) {
      return false;
    }

    const GuavaJoltBodyDesc &desc = entry->second.desc;
    if (filter.include_triggers == 0 &&
        (desc.flags & kFlagBodyIsSensor) != 0) {
      return false;
    }

    if (filter.has_layer_id != 0 && desc.layer_id != filter.layer_id) {
      return false;
    }

    return (desc.layer_group & filter.layer_group_mask) != 0;
  }

private:
  const GuavaJoltContext &context;
  const GuavaJoltQueryFilter &filter;
};

extern "C" {
GuavaJoltContext *
guava_jolt_context_create(const GuavaJoltStepConfig *in_config) {
  if (in_config == nullptr) {
    return nullptr;
  }

  EnsureInitialized();
  return new (std::nothrow) GuavaJoltContext(*in_config);
}

void guava_jolt_context_destroy(GuavaJoltContext *context) { delete context; }

bool guava_jolt_context_add_or_update_body(GuavaJoltContext *context,
                                           const GuavaJoltBodyDesc *desc,
                                           float delta_seconds) {
  if (context == nullptr || desc == nullptr) {
    return false;
  }

  JPH::ShapeRefC shape;
  if (!BuildBodyShape(*desc, shape)) {
    return context->RemoveBody(desc->entity_id);
  }

  return context->SyncExistingBody(*desc, delta_seconds);
}

bool guava_jolt_context_remove_body(GuavaJoltContext *context,
                                    uint64_t entity_id) {
  if (context == nullptr) {
    return false;
  }
  return context->RemoveBody(entity_id);
}

bool guava_jolt_context_add_or_update_constraint(
    GuavaJoltContext *context, const GuavaJoltConstraintDesc *desc) {
  if (context == nullptr || desc == nullptr) {
    return false;
  }
  return context->AddOrUpdateConstraint(*desc);
}

bool guava_jolt_context_remove_constraint(GuavaJoltContext *context,
                                          uint64_t entity_id) {
  if (context == nullptr) {
    return false;
  }
  return context->RemoveConstraint(entity_id);
}

bool guava_jolt_context_sync_snapshot(GuavaJoltContext *context,
                                      const GuavaJoltBodyDesc *in_bodies,
                                      size_t in_body_count,
                                      float delta_seconds) {
  if (context == nullptr) {
    return false;
  }

  return context->SyncBodiesSnapshot(in_bodies, in_body_count, delta_seconds);
}

bool guava_jolt_context_raycast(GuavaJoltContext *context,
                                const GuavaJoltRayQuery *query,
                                const GuavaJoltQueryFilter *filter,
                                GuavaJoltRaycastHit *out_hit) {
  if (context == nullptr || query == nullptr || filter == nullptr ||
      out_hit == nullptr || query->max_distance < 0.0f) {
    return false;
  }

  *out_hit = {};

  const JPH::RRayCast ray(
      ToRVec3(query->origin),
      ToVec3(query->direction) * query->max_distance);
  QueryBodyFilter body_filter(*context, *filter);

  JPH::RayCastResult hit;
  if (!context->physics_system.GetNarrowPhaseQuery().CastRay(
          ray, hit, {}, {}, body_filter)) {
    return true;
  }

  JPH::BodyLockRead lock(context->physics_system.GetBodyLockInterface(),
                         hit.mBodyID);
  if (!lock.Succeeded()) {
    return false;
  }

  const JPH::Body &body = lock.GetBody();
  const JPH::RVec3 hit_position = ray.GetPointOnRay(hit.mFraction);
  const JPH::Vec3 hit_normal =
      body.GetWorldSpaceSurfaceNormal(hit.mSubShapeID2, hit_position)
          .NormalizedOr(JPH::Vec3::sAxisZ());

  out_hit->entity_id = body.GetUserData();
  out_hit->distance = hit.mFraction * query->max_distance;
  StoreRVec3(hit_position, out_hit->position);
  StoreVec3(hit_normal, out_hit->normal);
  out_hit->is_trigger = body.IsSensor() ? 1 : 0;
  out_hit->reserved0 = 0;
  out_hit->reserved1 = 0;
  return true;
}

bool guava_jolt_context_overlap_aabb(GuavaJoltContext *context,
                                     const float center[3],
                                     const float half_extents[3],
                                     const GuavaJoltQueryFilter *filter,
                                     GuavaJoltOverlapHit *out_hits,
                                     size_t out_capacity,
                                     size_t *out_count) {
  if (context == nullptr || center == nullptr || half_extents == nullptr ||
      filter == nullptr || out_hits == nullptr || out_count == nullptr) {
    return false;
  }

  QueryBodyFilter body_filter(*context, *filter);
  JPH::BoxShape query_shape(ToPositiveHalfExtents(half_extents));
  JPH::ClosestHitPerBodyCollisionCollector<JPH::CollideShapeCollector>
      collector;
  JPH::CollideShapeSettings settings;
  context->physics_system.GetNarrowPhaseQuery().CollideShape(
      &query_shape, JPH::Vec3::sOne(),
      JPH::RMat44::sTranslation(ToRVec3(center)), settings, JPH::RVec3::sZero(),
      collector, {}, {}, body_filter);

  *out_count = 0;
  for (const JPH::CollideShapeResult &hit : collector.mHits) {
    if (*out_count >= out_capacity) {
      break;
    }

    JPH::BodyLockRead lock(context->physics_system.GetBodyLockInterface(),
                           hit.mBodyID2);
    if (!lock.Succeeded()) {
      continue;
    }

    const JPH::Body &body = lock.GetBody();
    GuavaJoltOverlapHit &out = out_hits[*out_count];
    out.entity_id = body.GetUserData();
    out.is_trigger = body.IsSensor() ? 1 : 0;
    out.reserved0 = 0;
    out.reserved1 = 0;
    *out_count += 1;
  }

  return true;
}

bool guava_jolt_context_sweep_aabb(GuavaJoltContext *context,
                                   const float center[3],
                                   const float half_extents[3],
                                   const float translation[3],
                                   const GuavaJoltQueryFilter *filter,
                                    GuavaJoltSweepHit *out_hit) {
  if (context == nullptr || center == nullptr || half_extents == nullptr ||
      translation == nullptr || filter == nullptr || out_hit == nullptr) {
    return false;
  }

  *out_hit = {};

  QueryBodyFilter body_filter(*context, *filter);
  JPH::BoxShape query_shape(ToPositiveHalfExtents(half_extents));
  const JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
      &query_shape, JPH::Vec3::sOne(),
      JPH::RMat44::sTranslation(ToRVec3(center)), ToVec3(translation));

  JPH::ClosestHitCollisionCollector<JPH::CastShapeCollector> collector;
  JPH::ShapeCastSettings settings;
  settings.mReturnDeepestPoint = true;
  context->physics_system.GetNarrowPhaseQuery().CastShape(
      shape_cast, settings, JPH::RVec3::sZero(), collector, {}, {}, body_filter);
  if (!collector.HadHit()) {
    return true;
  }

  JPH::BodyLockRead lock(context->physics_system.GetBodyLockInterface(),
                         collector.mHit.mBodyID2);
  if (!lock.Succeeded()) {
    return false;
  }

  const JPH::Body &body = lock.GetBody();
  const JPH::Vec3 hit_normal =
      (-collector.mHit.mPenetrationAxis)
          .NormalizedOr(JPH::Vec3::sAxisY());

  out_hit->entity_id = body.GetUserData();
  out_hit->fraction = collector.mHit.mFraction;
  out_hit->distance = collector.mHit.mFraction * ToVec3(translation).Length();
  StoreVec3(collector.mHit.mContactPointOn2, out_hit->position);
  StoreVec3(hit_normal, out_hit->normal);
  out_hit->is_trigger = body.IsSensor() ? 1 : 0;
  out_hit->reserved0 = 0;
  out_hit->reserved1 = 0;
  return true;
}

bool guava_jolt_context_step_incremental(GuavaJoltContext *context,
                                         float delta_seconds,
                                         uint32_t collision_steps,
                                         GuavaJoltBodyState *out_states,
                                         size_t in_state_capacity,
                                         GuavaJoltStepStats *out_stats) {
  if (context == nullptr || out_stats == nullptr) {
    return false;
  }

  *out_stats = {};
  context->contact_listener.Reset();

  JPH::BodyInterface &body_interface =
      context->physics_system.GetBodyInterface();
  for (const auto &entry : context->body_records) {
    switch (ToMotionType(entry.second.desc.motion_type)) {
    case JPH::EMotionType::Dynamic:
      ++out_stats->dynamic_bodies;
      break;
    case JPH::EMotionType::Static:
    case JPH::EMotionType::Kinematic:
      ++out_stats->static_bodies;
      break;
    }
  }

  const uint32_t allocator_size = 10 * 1024 * 1024;
  const int actual_collision_steps =
      std::max<int>(1, static_cast<int>(collision_steps));
  JPH::TempAllocatorImpl temp_allocator(static_cast<int>(allocator_size));
  const JPH::EPhysicsUpdateError update_error =
      context->physics_system.Update(delta_seconds, actual_collision_steps,
                                     &temp_allocator, &context->job_system);
  if (update_error != JPH::EPhysicsUpdateError::None) {
    return false;
  }

  size_t out_index = 0;
  for (auto &entry : context->body_records) {
    const JPH::EMotionType motion_type =
        ToMotionType(entry.second.desc.motion_type);
    if (motion_type == JPH::EMotionType::Static) {
      continue;
    }

    JPH::RVec3 position;
    JPH::Quat rotation;
    body_interface.GetPositionAndRotation(entry.second.body_id, position,
                                          rotation);
    const JPH::Vec3 linear_velocity =
        body_interface.GetLinearVelocity(entry.second.body_id);
    const JPH::Vec3 angular_velocity =
        body_interface.GetAngularVelocity(entry.second.body_id);

    if (out_index < in_state_capacity) {
      GuavaJoltBodyState &state = out_states[out_index++];
      state.entity_id = entry.first;
      state.position[0] = static_cast<float>(position.GetX());
      state.position[1] = static_cast<float>(position.GetY());
      state.position[2] = static_cast<float>(position.GetZ());
      state.rotation[0] = rotation.GetX();
      state.rotation[1] = rotation.GetY();
      state.rotation[2] = rotation.GetZ();
      state.rotation[3] = rotation.GetW();
      state.linear_velocity[0] = linear_velocity.GetX();
      state.linear_velocity[1] = linear_velocity.GetY();
      state.linear_velocity[2] = linear_velocity.GetZ();
      state.angular_velocity[0] = angular_velocity.GetX();
      state.angular_velocity[1] = angular_velocity.GetY();
      state.angular_velocity[2] = angular_velocity.GetZ();
    }

    entry.second.desc.position[0] = static_cast<float>(position.GetX());
    entry.second.desc.position[1] = static_cast<float>(position.GetY());
    entry.second.desc.position[2] = static_cast<float>(position.GetZ());
    entry.second.desc.rotation[0] = rotation.GetX();
    entry.second.desc.rotation[1] = rotation.GetY();
    entry.second.desc.rotation[2] = rotation.GetZ();
    entry.second.desc.rotation[3] = rotation.GetW();
    entry.second.desc.linear_velocity[0] = linear_velocity.GetX();
    entry.second.desc.linear_velocity[1] = linear_velocity.GetY();
    entry.second.desc.linear_velocity[2] = linear_velocity.GetZ();
  }

  out_stats->contacts_resolved = context->contact_listener.GetCount();
  out_stats->state_count = static_cast<uint32_t>(out_index);
  out_stats->success = 1;
  return true;
}

bool guava_jolt_context_step(GuavaJoltContext *context,
                             const GuavaJoltBodyDesc *in_bodies,
                             size_t in_body_count,
                             const GuavaJoltStepConfig *in_config,
                             GuavaJoltBodyState *out_states,
                             size_t in_state_capacity,
                             GuavaJoltStepStats *out_stats) {
  if (context == nullptr || out_stats == nullptr || in_config == nullptr) {
    return false;
  }

  *out_stats = {};
  context->contact_listener.Reset();
  context->physics_system.SetGravity(ToVec3(in_config->gravity));

  if (!context->SyncBodiesSnapshot(in_bodies, in_body_count,
                                   in_config->delta_seconds)) {
    return false;
  }

  JPH::BodyInterface &body_interface =
      context->physics_system.GetBodyInterface();
  for (const auto &entry : context->body_records) {
    switch (ToMotionType(entry.second.desc.motion_type)) {
    case JPH::EMotionType::Dynamic:
      ++out_stats->dynamic_bodies;
      break;
    case JPH::EMotionType::Static:
    case JPH::EMotionType::Kinematic:
      ++out_stats->static_bodies;
      break;
    }
  }

  const uint32_t allocator_size =
      std::max<uint32_t>(in_config->temp_allocator_size_bytes, 1024 * 1024);
  const int collision_steps =
      std::max<int>(1, static_cast<int>(in_config->collision_steps));
  JPH::TempAllocatorImpl temp_allocator(static_cast<int>(allocator_size));
  const JPH::EPhysicsUpdateError update_error =
      context->physics_system.Update(in_config->delta_seconds, collision_steps,
                                     &temp_allocator, &context->job_system);
  if (update_error != JPH::EPhysicsUpdateError::None) {
    return false;
  }

  size_t out_index = 0;
  for (auto &entry : context->body_records) {
    const JPH::EMotionType motion_type =
        ToMotionType(entry.second.desc.motion_type);
    if (motion_type == JPH::EMotionType::Static) {
      continue;
    }

    JPH::RVec3 position;
    JPH::Quat rotation;
    body_interface.GetPositionAndRotation(entry.second.body_id, position,
                                          rotation);
    const JPH::Vec3 linear_velocity =
        body_interface.GetLinearVelocity(entry.second.body_id);
    const JPH::Vec3 angular_velocity =
        body_interface.GetAngularVelocity(entry.second.body_id);

    if (out_index < in_state_capacity) {
      GuavaJoltBodyState &state = out_states[out_index++];
      state.entity_id = entry.first;
      state.position[0] = static_cast<float>(position.GetX());
      state.position[1] = static_cast<float>(position.GetY());
      state.position[2] = static_cast<float>(position.GetZ());
      state.rotation[0] = rotation.GetX();
      state.rotation[1] = rotation.GetY();
      state.rotation[2] = rotation.GetZ();
      state.rotation[3] = rotation.GetW();
      state.linear_velocity[0] = linear_velocity.GetX();
      state.linear_velocity[1] = linear_velocity.GetY();
      state.linear_velocity[2] = linear_velocity.GetZ();
      state.angular_velocity[0] = angular_velocity.GetX();
      state.angular_velocity[1] = angular_velocity.GetY();
      state.angular_velocity[2] = angular_velocity.GetZ();
    }

    entry.second.desc.position[0] = static_cast<float>(position.GetX());
    entry.second.desc.position[1] = static_cast<float>(position.GetY());
    entry.second.desc.position[2] = static_cast<float>(position.GetZ());
    entry.second.desc.rotation[0] = rotation.GetX();
    entry.second.desc.rotation[1] = rotation.GetY();
    entry.second.desc.rotation[2] = rotation.GetZ();
    entry.second.desc.rotation[3] = rotation.GetW();
    entry.second.desc.linear_velocity[0] = linear_velocity.GetX();
    entry.second.desc.linear_velocity[1] = linear_velocity.GetY();
    entry.second.desc.linear_velocity[2] = linear_velocity.GetZ();
  }

  out_stats->contacts_resolved = context->contact_listener.GetCount();
  out_stats->state_count = static_cast<uint32_t>(out_index);
  out_stats->success = 1;
  return true;
}
}
