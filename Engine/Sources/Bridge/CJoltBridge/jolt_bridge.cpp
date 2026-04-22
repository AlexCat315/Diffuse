#include "jolt_bridge.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <unordered_map>
#include <vector>

namespace {

constexpr uint32_t kRigidBodyAllowSleepFlag = 1u << 4;
constexpr uint32_t kMotionDynamic = 1u;
constexpr uint32_t kMotionKinematic = 2u;

struct BodyRecord {
    GuavaJoltBodyDesc desc {};
    GuavaJoltBodyState state {};
};

static GuavaJoltBodyState make_body_state(const GuavaJoltBodyDesc& desc) {
    GuavaJoltBodyState state {};
    state.entity_id = desc.entity_id;
    state.position_x = desc.position_x;
    state.position_y = desc.position_y;
    state.position_z = desc.position_z;
    state.rotation_x = desc.rotation_x;
    state.rotation_y = desc.rotation_y;
    state.rotation_z = desc.rotation_z;
    state.rotation_w = desc.rotation_w;
    state.linear_velocity_x = desc.linear_velocity_x;
    state.linear_velocity_y = desc.linear_velocity_y;
    state.linear_velocity_z = desc.linear_velocity_z;
    state.angular_velocity_x = desc.angular_velocity_x;
    state.angular_velocity_y = desc.angular_velocity_y;
    state.angular_velocity_z = desc.angular_velocity_z;
    state.is_sleeping = desc.is_sleeping;
    state.reserved0 = 0;
    state.reserved1 = 0;
    return state;
}

static float damping_factor(float damping, float delta_seconds) {
    const float factor = 1.0f - damping * delta_seconds;
    return std::max(0.0f, std::min(1.0f, factor));
}

static float length_squared(float x, float y, float z) {
    return (x * x) + (y * y) + (z * z);
}

static void integrate_body(BodyRecord& body, const GuavaJoltStepConfig& config) {
    if (body.desc.motion_type == kMotionDynamic) {
        if (body.state.is_sleeping != 0) {
            return;
        }

        body.state.linear_velocity_x += config.gravity_x * body.desc.gravity_scale * config.delta_seconds;
        body.state.linear_velocity_y += config.gravity_y * body.desc.gravity_scale * config.delta_seconds;
        body.state.linear_velocity_z += config.gravity_z * body.desc.gravity_scale * config.delta_seconds;

        const float linearDamping = damping_factor(body.desc.linear_damping, config.delta_seconds);
        const float angularDamping = damping_factor(body.desc.angular_damping, config.delta_seconds);
        body.state.linear_velocity_x *= linearDamping;
        body.state.linear_velocity_y *= linearDamping;
        body.state.linear_velocity_z *= linearDamping;
        body.state.angular_velocity_x *= angularDamping;
        body.state.angular_velocity_y *= angularDamping;
        body.state.angular_velocity_z *= angularDamping;

        body.state.position_x += body.state.linear_velocity_x * config.delta_seconds;
        body.state.position_y += body.state.linear_velocity_y * config.delta_seconds;
        body.state.position_z += body.state.linear_velocity_z * config.delta_seconds;

        const bool canSleep = config.allow_sleep != 0 && (body.desc.flags & kRigidBodyAllowSleepFlag) != 0;
        if (canSleep) {
            const float linearSpeedSq = length_squared(
                body.state.linear_velocity_x,
                body.state.linear_velocity_y,
                body.state.linear_velocity_z
            );
            const float angularSpeedSq = length_squared(
                body.state.angular_velocity_x,
                body.state.angular_velocity_y,
                body.state.angular_velocity_z
            );
            body.state.is_sleeping = (linearSpeedSq < 0.0001f && angularSpeedSq < 0.0001f) ? 1 : 0;
        } else {
            body.state.is_sleeping = 0;
        }
        return;
    }

    if (body.desc.motion_type == kMotionKinematic) {
        body.state.position_x += body.state.linear_velocity_x * config.delta_seconds;
        body.state.position_y += body.state.linear_velocity_y * config.delta_seconds;
        body.state.position_z += body.state.linear_velocity_z * config.delta_seconds;
        body.state.is_sleeping = 0;
    }
}

}  // namespace

struct GuavaJoltContextImpl {
    std::unordered_map<uint64_t, BodyRecord> bodies;
    std::unordered_map<uint64_t, GuavaJoltConstraintDesc> constraints;
};

GuavaJoltContext guava_jolt_context_create(void) {
    return new (std::nothrow) GuavaJoltContextImpl();
}

void guava_jolt_context_destroy(GuavaJoltContext context) {
    delete context;
}

void guava_jolt_context_reset(GuavaJoltContext context) {
    if (context == nullptr) {
        return;
    }
    context->bodies.clear();
    context->constraints.clear();
}

bool guava_jolt_context_prepare(GuavaJoltContext context,
                                const GuavaJoltBodyDesc* bodies,
                                size_t body_count,
                                const GuavaJoltConstraintDesc* constraints,
                                size_t constraint_count,
                                GuavaJoltPrepareStats* out_stats) {
    if (context == nullptr || out_stats == nullptr) {
        return false;
    }

    std::unordered_map<uint64_t, BodyRecord> nextBodies;
    if (bodies != nullptr) {
        nextBodies.reserve(body_count);
        for (size_t index = 0; index < body_count; ++index) {
            const GuavaJoltBodyDesc& desc = bodies[index];
            nextBodies[desc.entity_id] = BodyRecord {
                .desc = desc,
                .state = make_body_state(desc),
            };
        }
    }

    std::unordered_map<uint64_t, GuavaJoltConstraintDesc> nextConstraints;
    if (constraints != nullptr) {
        nextConstraints.reserve(constraint_count);
        for (size_t index = 0; index < constraint_count; ++index) {
            const GuavaJoltConstraintDesc& desc = constraints[index];
            nextConstraints[desc.entity_id] = desc;
        }
    }

    uint32_t removedBodies = 0;
    for (std::unordered_map<uint64_t, BodyRecord>::const_iterator it = context->bodies.begin();
         it != context->bodies.end();
         ++it) {
        if (nextBodies.find(it->first) == nextBodies.end()) {
            ++removedBodies;
        }
    }

    uint32_t removedConstraints = 0;
    for (std::unordered_map<uint64_t, GuavaJoltConstraintDesc>::const_iterator it = context->constraints.begin();
         it != context->constraints.end();
         ++it) {
        if (nextConstraints.find(it->first) == nextConstraints.end()) {
            ++removedConstraints;
        }
    }

    context->bodies.swap(nextBodies);
    context->constraints.swap(nextConstraints);

    out_stats->synchronized_bodies = static_cast<uint32_t>(context->bodies.size());
    out_stats->synchronized_constraints = static_cast<uint32_t>(context->constraints.size());
    out_stats->removed_bodies = removedBodies;
    out_stats->removed_constraints = removedConstraints;
    return true;
}

bool guava_jolt_context_step(GuavaJoltContext context,
                             const GuavaJoltStepConfig* config,
                             GuavaJoltBodyState* states,
                             size_t state_count,
                             GuavaJoltStepStats* out_stats) {
    if (context == nullptr || config == nullptr || out_stats == nullptr) {
        return false;
    }

    if (states == nullptr && state_count > 0) {
        return false;
    }

    std::vector<uint64_t> entityIDs;
    entityIDs.reserve(context->bodies.size());
    for (std::unordered_map<uint64_t, BodyRecord>::const_iterator it = context->bodies.begin();
         it != context->bodies.end();
         ++it) {
        entityIDs.push_back(it->first);
    }
    std::sort(entityIDs.begin(), entityIDs.end());

    size_t writtenStates = 0;
    for (uint64_t entityID : entityIDs) {
        BodyRecord& body = context->bodies.at(entityID);
        integrate_body(body, *config);
        if (writtenStates < state_count) {
            states[writtenStates] = body.state;
            ++writtenStates;
        }
    }

    out_stats->body_count = static_cast<uint32_t>(context->bodies.size());
    out_stats->constraint_count = static_cast<uint32_t>(context->constraints.size());
    out_stats->contact_count = 0;
    out_stats->state_count = static_cast<uint32_t>(writtenStates);
    out_stats->success = 1;
    out_stats->reserved0 = 0;
    out_stats->reserved1 = 0;
    return true;
}