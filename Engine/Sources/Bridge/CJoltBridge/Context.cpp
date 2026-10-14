#include "Internal.hpp"

using namespace jolt;

// --- process-wide Jolt bootstrap ---

// Declared in Internal.hpp; the once_flag stays translation-unit local, so this
// translation unit holds the only definition.
namespace jolt {

std::once_flag g_jolt_init;

void ensure_jolt_initialized() {
    std::call_once(g_jolt_init, []() {
        JPH::RegisterDefaultAllocator();
        JPH::Factory::sInstance = new JPH::Factory();
        JPH::RegisterTypes();
    });
}

}  // namespace jolt

// --- construction and teardown ---

GuavaJoltContextImpl::GuavaJoltContextImpl(const GuavaJoltContextConfig& config)
    : events(bodies.metadata) {
    const JPH::uint cMaxBodies = config.max_bodies;
    const JPH::uint cNumBodyMutexes = config.body_mutex_count;
    const JPH::uint cMaxBodyPairs = config.max_body_pairs;
    const JPH::uint cMaxContactConstraints = config.max_contact_constraints;
    physics_system.Init(cMaxBodies, cNumBodyMutexes, cMaxBodyPairs, cMaxContactConstraints,
                        bp_layer_interface, object_vs_bp_filter, object_layer_filter);
    physics_system.SetContactListener(&events.contact_listener);
    temp_allocator = std::make_unique<JPH::TempAllocatorImpl>(
        static_cast<uint32_t>(config.temp_allocator_bytes));
    const unsigned hardware_threads = std::thread::hardware_concurrency();
    const int worker_threads = config.worker_thread_count == 0
        ? static_cast<int>(hardware_threads > 1 ? hardware_threads - 1 : 1)
        : static_cast<int>(config.worker_thread_count);
    job_system = std::make_unique<JPH::JobSystemThreadPool>(
        JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers, worker_threads);
}

GuavaJoltContextImpl::~GuavaJoltContextImpl() {
    physics_system.SetContactListener(nullptr);
    characters.clear();
    kinematic_targets.clear();
    // Remove all bodies and constraints before destruction.
    JPH::BodyInterface& bi = physics_system.GetBodyInterface();
    for (auto& kv : vehicles) {
        if (kv.second.constraint) {
            physics_system.RemoveStepListener(kv.second.constraint);
            physics_system.RemoveConstraint(kv.second.constraint);
        }
    }
    vehicles.clear();
    for (auto& kv : joints.native) {
        if (kv.second) physics_system.RemoveConstraint(kv.second);
    }
    for (auto& kv : bodies.ids) {
        bi.RemoveBody(kv.second);
        bi.DestroyBody(kv.second);
    }
    for (auto& kv : soft_bodies.ids) {
        bi.RemoveBody(kv.second);
        bi.DestroyBody(kv.second);
    }
    soft_bodies.self_collisions.clear();
}

// --- whole-world reset ---

// Drops every simulated entity the context owns while keeping the Jolt factory
// and its worker pool alive, so the context stays usable for the next session.
void GuavaJoltContextImpl::clear_all() {
    JPH::BodyInterface& bi = physics_system.GetBodyInterface();
    for (auto& kv : vehicles) {
        if (kv.second.constraint) {
            physics_system.RemoveStepListener(kv.second.constraint);
            physics_system.RemoveConstraint(kv.second.constraint);
        }
    }
    vehicles.clear();
    for (auto& kv : joints.native) {
        if (kv.second) physics_system.RemoveConstraint(kv.second);
    }
    joints.native.clear();
    joints.descriptors.clear();
    joints.bodies.clear();
    events.joint_break_events.clear();
    characters.clear();
    for (auto& kv : bodies.ids) {
        bi.RemoveBody(kv.second);
        bi.DestroyBody(kv.second);
    }
    bodies.ids.clear();
    for (auto& kv : soft_bodies.ids) {
        bi.RemoveBody(kv.second);
        bi.DestroyBody(kv.second);
    }
    soft_bodies.ids.clear();
    soft_bodies.self_collisions.clear();
    bodies.metadata.clear();
    bodies.signatures.clear();
    meshes.vertices.clear();
    meshes.indices.clear();
    meshes.revisions.clear();
    events.previous_trigger_pairs.clear();
    events.contact_listener.reset();
}

