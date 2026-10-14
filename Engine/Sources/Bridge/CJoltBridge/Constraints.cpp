#include "Internal.hpp"

using namespace jolt;

// Constraint teardown.


bool GuavaJoltContextImpl::destroy_constraint(uint64_t entity) {
    auto existing = joints.native.find(entity);
    if (existing == joints.native.end()) return false;
    if (existing->second) physics_system.RemoveConstraint(existing->second);
    joints.native.erase(existing);
    joints.descriptors.erase(entity);
    joints.bodies.erase(entity);
    return true;
    }

uint32_t GuavaJoltContextImpl::destroy_constraints_for_body(uint64_t body_entity) {
    std::vector<uint64_t> affected;
    for (const auto& entry : joints.bodies) {
        if (entry.second.first == body_entity || entry.second.second == body_entity) {
            affected.push_back(entry.first);
        }
    }
    std::sort(affected.begin(), affected.end());
    uint32_t removed = 0;
    for (uint64_t constraint_entity : affected) {
        if (destroy_constraint(constraint_entity)) ++removed;
    }
    return removed;
    }

