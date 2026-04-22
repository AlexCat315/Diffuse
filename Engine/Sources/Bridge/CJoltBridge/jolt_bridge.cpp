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
constexpr uint8_t kConstraintDistance = 3u;

struct BodyRecord {
    GuavaJoltBodyDesc desc {};
    GuavaJoltBodyState state {};
};

struct Quat {
    float x;
    float y;
    float z;
    float w;
};

struct Vec3 {
    float x;
    float y;
    float z;
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

static Vec3 make_vec3(float x, float y, float z) {
    return Vec3 {x, y, z};
}

static Vec3 add_vec3(const Vec3& lhs, const Vec3& rhs) {
    return make_vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z);
}

static Vec3 sub_vec3(const Vec3& lhs, const Vec3& rhs) {
    return make_vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z);
}

static Vec3 scale_vec3(const Vec3& vector, float scalar) {
    return make_vec3(vector.x * scalar, vector.y * scalar, vector.z * scalar);
}

static float length_vec3(const Vec3& vector) {
    return std::sqrt(length_squared(vector.x, vector.y, vector.z));
}

static Vec3 normalize_vec3(const Vec3& vector) {
    const float magnitude = length_vec3(vector);
    if (magnitude <= 0.000001f) {
        return make_vec3(1.0f, 0.0f, 0.0f);
    }
    return scale_vec3(vector, 1.0f / magnitude);
}

static Vec3 body_position(const GuavaJoltBodyState& state) {
    return make_vec3(state.position_x, state.position_y, state.position_z);
}

static void set_body_position(GuavaJoltBodyState& state, const Vec3& position) {
    state.position_x = position.x;
    state.position_y = position.y;
    state.position_z = position.z;
}

static bool body_is_dynamic(const BodyRecord& body) {
    return body.desc.motion_type == kMotionDynamic;
}

static float inverse_mass(const BodyRecord& body) {
    if (!body_is_dynamic(body)) {
        return 0.0f;
    }
    if (body.desc.mass <= 0.000001f) {
        return 1.0f;
    }
    return 1.0f / body.desc.mass;
}

static void damp_velocity_along_axis(BodyRecord& body, const Vec3& axis) {
    if (!body_is_dynamic(body)) {
        return;
    }

    const float along = body.state.linear_velocity_x * axis.x
        + body.state.linear_velocity_y * axis.y
        + body.state.linear_velocity_z * axis.z;
    if (along == 0.0f) {
        return;
    }

    body.state.linear_velocity_x -= axis.x * along;
    body.state.linear_velocity_y -= axis.y * along;
    body.state.linear_velocity_z -= axis.z * along;
}

static Quat normalize_quat(Quat quat) {
    const float magnitude = std::sqrt(
        quat.x * quat.x + quat.y * quat.y + quat.z * quat.z + quat.w * quat.w
    );
    if (magnitude <= 0.000001f) {
        return Quat {0.0f, 0.0f, 0.0f, 1.0f};
    }

    const float inverseMagnitude = 1.0f / magnitude;
    return Quat {
        quat.x * inverseMagnitude,
        quat.y * inverseMagnitude,
        quat.z * inverseMagnitude,
        quat.w * inverseMagnitude,
    };
}

static Quat multiply_quat(const Quat& lhs, const Quat& rhs) {
    return Quat {
        lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
        lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
        lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
    };
}

static void integrate_rotation(GuavaJoltBodyState& state, float delta_seconds) {
    const float angularSpeed = std::sqrt(length_squared(
        state.angular_velocity_x,
        state.angular_velocity_y,
        state.angular_velocity_z
    ));
    if (angularSpeed <= 0.000001f) {
        return;
    }

    const float angle = angularSpeed * delta_seconds;
    const float inverseSpeed = 1.0f / angularSpeed;
    const float halfAngle = 0.5f * angle;
    const float sinHalf = std::sin(halfAngle);
    const Quat delta = Quat {
        state.angular_velocity_x * inverseSpeed * sinHalf,
        state.angular_velocity_y * inverseSpeed * sinHalf,
        state.angular_velocity_z * inverseSpeed * sinHalf,
        std::cos(halfAngle),
    };
    const Quat current = Quat {
        state.rotation_x,
        state.rotation_y,
        state.rotation_z,
        state.rotation_w,
    };
    const Quat integrated = normalize_quat(multiply_quat(delta, current));
    state.rotation_x = integrated.x;
    state.rotation_y = integrated.y;
    state.rotation_z = integrated.z;
    state.rotation_w = integrated.w;
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
        integrate_rotation(body.state, config.delta_seconds);

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
        integrate_rotation(body.state, config.delta_seconds);
        body.state.is_sleeping = 0;
    }
}

static bool solve_distance_constraint(BodyRecord& bodyA,
                                      BodyRecord& bodyB,
                                      const GuavaJoltConstraintDesc& constraint) {
    if (constraint.is_enabled == 0) {
        return false;
    }
    if (constraint.constraint_type != kConstraintDistance) {
        return false;
    }

    const Vec3 anchorA = add_vec3(body_position(bodyA.state), make_vec3(
        constraint.pivot_a_x,
        constraint.pivot_a_y,
        constraint.pivot_a_z
    ));
    const Vec3 anchorB = add_vec3(body_position(bodyB.state), make_vec3(
        constraint.pivot_b_x,
        constraint.pivot_b_y,
        constraint.pivot_b_z
    ));
    const Vec3 delta = sub_vec3(anchorB, anchorA);
    const float distance = length_vec3(delta);
    const float minLimit = std::max(0.0f, constraint.min_limit);
    const float maxLimit = constraint.max_limit >= minLimit ? constraint.max_limit : minLimit;

    float clampedDistance = distance;
    if (distance < minLimit) {
        clampedDistance = minLimit;
    } else if (distance > maxLimit) {
        clampedDistance = maxLimit;
    } else {
        return false;
    }

    const float error = distance - clampedDistance;
    const Vec3 axis = normalize_vec3(delta);
    const float inverseMassA = inverse_mass(bodyA);
    const float inverseMassB = inverse_mass(bodyB);
    const float inverseMassTotal = inverseMassA + inverseMassB;
    if (inverseMassTotal <= 0.000001f) {
        return false;
    }

    const float weightA = inverseMassA / inverseMassTotal;
    const float weightB = inverseMassB / inverseMassTotal;
    const Vec3 correctionA = scale_vec3(axis, error * weightA);
    const Vec3 correctionB = scale_vec3(axis, -error * weightB);

    if (inverseMassA > 0.0f) {
        set_body_position(bodyA.state, add_vec3(body_position(bodyA.state), correctionA));
        damp_velocity_along_axis(bodyA, axis);
    }
    if (inverseMassB > 0.0f) {
        set_body_position(bodyB.state, add_vec3(body_position(bodyB.state), correctionB));
        damp_velocity_along_axis(bodyB, axis);
    }
    return true;
}

}  // namespace

struct GuavaJoltContextImpl {
    std::unordered_map<uint64_t, BodyRecord> bodies;
    std::unordered_map<uint64_t, GuavaJoltConstraintDesc> constraints;
};

namespace {

static uint32_t solve_constraints(GuavaJoltContextImpl& context) {
    uint32_t solvedCount = 0;
    for (std::unordered_map<uint64_t, GuavaJoltConstraintDesc>::const_iterator it = context.constraints.begin();
         it != context.constraints.end();
         ++it) {
        const GuavaJoltConstraintDesc& constraint = it->second;
        std::unordered_map<uint64_t, BodyRecord>::iterator bodyA = context.bodies.find(constraint.entity_a);
        std::unordered_map<uint64_t, BodyRecord>::iterator bodyB = context.bodies.find(constraint.entity_b);
        if (bodyA == context.bodies.end() || bodyB == context.bodies.end()) {
            continue;
        }
        if (solve_distance_constraint(bodyA->second, bodyB->second, constraint)) {
            ++solvedCount;
        }
    }
    return solvedCount;
}

}  // namespace

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
    }

    const uint32_t solvedConstraints = solve_constraints(*context);

    for (std::vector<uint64_t>::const_iterator it = entityIDs.begin();
         it != entityIDs.end();
         ++it) {
        BodyRecord& body = context->bodies.at(*it);
        if (writtenStates < state_count) {
            states[writtenStates] = body.state;
            ++writtenStates;
        }
    }

    out_stats->body_count = static_cast<uint32_t>(context->bodies.size());
    out_stats->constraint_count = static_cast<uint32_t>(context->constraints.size());
    out_stats->contact_count = solvedConstraints;
    out_stats->state_count = static_cast<uint32_t>(writtenStates);
    out_stats->success = 1;
    out_stats->reserved0 = 0;
    out_stats->reserved1 = 0;
    return true;
}