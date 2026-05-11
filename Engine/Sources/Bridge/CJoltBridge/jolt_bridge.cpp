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
#include <Jolt/Physics/Collision/Shape/MeshShape.h>
#include <Jolt/Physics/Collision/Shape/ConvexHullShape.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Constraints/PointConstraint.h>
#include <Jolt/Physics/Constraints/SliderConstraint.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace {

// Bridge flag constants (must match Swift `JoltPhysicsBackend`).
constexpr uint32_t kColliderHasBoxFlag     = 1u << 0;
constexpr uint32_t kColliderHasSphereFlag  = 1u << 1;
constexpr uint32_t kColliderHasMeshFlag    = 1u << 2;
constexpr uint32_t kColliderIsTriggerFlag  = 1u << 3;
constexpr uint32_t kRigidBodyAllowSleepFlag = 1u << 4;
constexpr uint32_t kColliderHasCapsuleFlag = 1u << 5;
constexpr uint32_t kColliderHasConvexFlag  = 1u << 6;

constexpr uint32_t kMotionStatic    = 0u;
constexpr uint32_t kMotionDynamic   = 1u;
constexpr uint32_t kMotionKinematic = 2u;

constexpr uint8_t kConstraintPointToPoint = 0u;
constexpr uint8_t kConstraintSlider       = 2u;
constexpr uint8_t kConstraintDistance     = 3u;

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

// Build a Shape from the descriptor's flag+geom fields. Returns null if unsupported.
JPH::ShapeRefC build_shape(const GuavaJoltBodyDesc& desc,
                            const float* mesh_vertices, uint32_t mesh_vertex_count,
                            const uint32_t* mesh_indices, uint32_t mesh_index_count) {
    if (desc.flags & kColliderHasBoxFlag) {
        JPH::BoxShapeSettings settings(JPH::Vec3(
            desc.box_half_extent_x, desc.box_half_extent_y, desc.box_half_extent_z));
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return r.Get();
    }
    if (desc.flags & kColliderHasSphereFlag) {
        JPH::SphereShapeSettings settings(desc.sphere_radius);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return r.Get();
    }
    if (desc.flags & kColliderHasCapsuleFlag) {
        JPH::CapsuleShapeSettings settings(desc.capsule_half_height, desc.capsule_radius);
        settings.SetEmbedded();
        JPH::ShapeSettings::ShapeResult r = settings.Create();
        if (r.IsValid()) return r.Get();
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
        if (r.IsValid()) return r.Get();
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
        if (r.IsValid()) return r.Get();
    }
    return nullptr;
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

}  // namespace

struct GuavaJoltContextImpl {
    BPLayerInterfaceImpl bp_layer_interface;
    ObjectVsBPLayerFilterImpl object_vs_bp_filter;
    ObjectLayerPairFilterImpl object_layer_filter;
    JPH::PhysicsSystem physics_system;
    std::unique_ptr<JPH::TempAllocatorImpl> temp_allocator;
    std::unique_ptr<JPH::JobSystemThreadPool> job_system;

    std::unordered_map<uint64_t, JPH::BodyID> body_ids;            // entity → Jolt body
    std::unordered_map<uint64_t, JPH::Ref<JPH::Constraint>> constraints; // entity → constraint
    std::unordered_map<uint64_t, std::vector<float>>    mesh_vertices;
    std::unordered_map<uint64_t, std::vector<uint32_t>> mesh_indices;

    GuavaJoltContextImpl() {
        const JPH::uint cMaxBodies            = 65536;
        const JPH::uint cNumBodyMutexes       = 0;
        const JPH::uint cMaxBodyPairs         = 65536;
        const JPH::uint cMaxContactConstraints = 10240;
        physics_system.Init(cMaxBodies, cNumBodyMutexes, cMaxBodyPairs, cMaxContactConstraints,
                            bp_layer_interface, object_vs_bp_filter, object_layer_filter);
        temp_allocator = std::make_unique<JPH::TempAllocatorImpl>(10 * 1024 * 1024);
        job_system = std::make_unique<JPH::JobSystemThreadPool>(
            JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers, 1);
    }

    ~GuavaJoltContextImpl() {
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
        for (auto& kv : body_ids) {
            bi.RemoveBody(kv.second);
            bi.DestroyBody(kv.second);
        }
        body_ids.clear();
        mesh_vertices.clear();
        mesh_indices.clear();
    }

    bool prepare(const GuavaJoltBodyDesc* bodies, size_t body_count,
                 const GuavaJoltConstraintDesc* constraints_in, size_t constraint_count,
                 const GuavaJoltMeshGeometry* meshes, size_t mesh_count,
                 GuavaJoltPrepareStats* out_stats) {
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
                it = body_ids.erase(it);
                ++removed_bodies;
            } else {
                ++it;
            }
        }

        // Add / refresh bodies in incoming.
        for (auto& kv : incoming) {
            const uint64_t entity = kv.first;
            const GuavaJoltBodyDesc& desc = *kv.second;
            auto existing = body_ids.find(entity);
            if (existing != body_ids.end()) {
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
                if (desc.motion_type == kMotionDynamic) {
                    bi.AddForce(existing->second, JPH::Vec3(
                        desc.accumulated_force_x, desc.accumulated_force_y, desc.accumulated_force_z));
                    bi.AddTorque(existing->second, JPH::Vec3(
                        desc.accumulated_torque_x, desc.accumulated_torque_y, desc.accumulated_torque_z));
                }
                continue;
            }

            // Build shape using stored mesh data if needed.
            const std::vector<float>* mv = nullptr;
            const std::vector<uint32_t>* mi = nullptr;
            auto mv_it = mesh_vertices.find(entity);
            auto mi_it = mesh_indices.find(entity);
            if (mv_it != mesh_vertices.end()) mv = &mv_it->second;
            if (mi_it != mesh_indices.end()) mi = &mi_it->second;
            JPH::ShapeRefC shape = build_shape(
                desc,
                mv ? mv->data() : nullptr,
                mv ? static_cast<uint32_t>(mv->size() / 3) : 0u,
                mi ? mi->data() : nullptr,
                mi ? static_cast<uint32_t>(mi->size()) : 0u);
            if (!shape) {
                // Default to a tiny box for unsupported / unspecified shapes so the
                // body still exists and tracks transform.
                JPH::BoxShapeSettings settings(JPH::Vec3(0.05f, 0.05f, 0.05f));
                settings.SetEmbedded();
                shape = settings.Create().Get();
            }

            JPH::EMotionType motion = to_motion_type(desc.motion_type);
            JPH::ObjectLayer layer = object_layer_for(motion);

            JPH::BodyCreationSettings settings(
                shape,
                JPH::RVec3(desc.position_x, desc.position_y, desc.position_z),
                JPH::Quat(desc.rotation_x, desc.rotation_y, desc.rotation_z, desc.rotation_w),
                motion, layer);
            settings.mLinearVelocity = JPH::Vec3(
                desc.linear_velocity_x, desc.linear_velocity_y, desc.linear_velocity_z);
            settings.mAngularVelocity = JPH::Vec3(
                desc.angular_velocity_x, desc.angular_velocity_y, desc.angular_velocity_z);
            settings.mLinearDamping = desc.linear_damping;
            settings.mAngularDamping = desc.angular_damping;
            settings.mGravityFactor = desc.gravity_scale;
            settings.mIsSensor = (desc.flags & kColliderIsTriggerFlag) != 0;
            settings.mAllowSleeping = (desc.flags & kRigidBodyAllowSleepFlag) != 0;
            if (motion == JPH::EMotionType::Dynamic) {
                settings.mOverrideMassProperties = JPH::EOverrideMassProperties::CalculateInertia;
                settings.mMassPropertiesOverride.mMass = desc.mass > 0.0f ? desc.mass : 1.0f;
            }

            JPH::Body* body = bi.CreateBody(settings);
            if (body) {
                bi.AddBody(body->GetID(), JPH::EActivation::Activate);
                body_ids[entity] = body->GetID();
                if (motion == JPH::EMotionType::Dynamic) {
                    bi.AddForce(body->GetID(), JPH::Vec3(
                        desc.accumulated_force_x, desc.accumulated_force_y, desc.accumulated_force_z));
                    bi.AddTorque(body->GetID(), JPH::Vec3(
                        desc.accumulated_torque_x, desc.accumulated_torque_y, desc.accumulated_torque_z));
                }
            }
        }

        // Re-sync constraints (drop existing, recreate from incoming).
        uint32_t removed_constraints = static_cast<uint32_t>(constraints.size());
        for (auto& kv : constraints) {
            if (kv.second) physics_system.RemoveConstraint(kv.second);
        }
        constraints.clear();

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
                } else if (c.constraint_type == kConstraintSlider) {
                    JPH::SliderConstraintSettings s;
                    s.mPoint1 = JPH::RVec3(c.pivot_a_x, c.pivot_a_y, c.pivot_a_z);
                    s.mPoint2 = JPH::RVec3(c.pivot_b_x, c.pivot_b_y, c.pivot_b_z);
                    s.mSliderAxis1 = JPH::Vec3(c.axis_a_x, c.axis_a_y, c.axis_a_z).Normalized();
                    s.mSliderAxis2 = JPH::Vec3(c.axis_b_x, c.axis_b_y, c.axis_b_z).Normalized();
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
        if (!config || !out_stats) return false;
        physics_system.SetGravity(JPH::Vec3(config->gravity_x, config->gravity_y, config->gravity_z));

        const int collision_steps = 1;
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
        out_stats->contact_count = 0; // not surfaced from Jolt's public API here
        out_stats->state_count = static_cast<uint32_t>(written);
        out_stats->success = 1;
        out_stats->reserved0 = 0;
        out_stats->reserved1 = 0;
        return true;
    }
};

extern "C" {

GuavaJoltContext guava_jolt_context_create(void) {
    ensure_jolt_initialized();
    return new (std::nothrow) GuavaJoltContextImpl();
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

}  // extern "C"
