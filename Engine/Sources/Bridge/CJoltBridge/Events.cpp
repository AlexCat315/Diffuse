#include "Internal.hpp"

using namespace jolt;

// Trigger overlap detection and contact / joint-break drain.

uint32_t GuavaJoltContextImpl::detect_triggers(GuavaJoltTriggerEvent* out_events, size_t event_capacity) {
    std::unordered_set<TriggerPair, TriggerPairHash> current_pairs;

    for (const auto& kv : bodies.metadata) {
        const uint64_t trigger_entity = kv.first;
        const BodyMetadata& trigger_metadata = kv.second;
        if (!trigger_metadata.is_trigger) continue;
        auto body_it = bodies.ids.find(trigger_entity);
        if (body_it == bodies.ids.end()) continue;

        JPH::BodyLockRead trigger_lock(physics_system.GetBodyLockInterface(), body_it->second);
        if (!trigger_lock.Succeeded()) continue;
        const JPH::Body& trigger_body = trigger_lock.GetBody();
        TriggerBodyFilter body_filter(bodies.metadata, trigger_entity, trigger_metadata);
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

    std::vector<GuavaJoltTriggerEvent> emitted;
    emitted.reserve(current_pairs.size() + events.previous_trigger_pairs.size());
    for (const TriggerPair& pair : current_pairs) {
        if (events.previous_trigger_pairs.find(pair) == events.previous_trigger_pairs.end()) {
            emitted.push_back(GuavaJoltTriggerEvent{ pair.trigger, pair.other, kTriggerEnter, 0, 0 });
        }
    }
    for (const TriggerPair& pair : events.previous_trigger_pairs) {
        if (current_pairs.find(pair) == current_pairs.end()) {
            emitted.push_back(GuavaJoltTriggerEvent{ pair.trigger, pair.other, kTriggerExit, 0, 0 });
        }
    }
    for (const TriggerPair& pair : current_pairs) {
        emitted.push_back(GuavaJoltTriggerEvent{ pair.trigger, pair.other, kTriggerActive, 0, 0 });
    }
    std::sort(emitted.begin(), emitted.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
        if (lhs.trigger_entity != rhs.trigger_entity) return lhs.trigger_entity < rhs.trigger_entity;
        return lhs.other_entity < rhs.other_entity;
    });

    events.previous_trigger_pairs = std::move(current_pairs);
    if (out_events && event_capacity > 0) {
        const size_t count = std::min(event_capacity, emitted.size());
        for (size_t i = 0; i < count; ++i) out_events[i] = emitted[i];
    }
    return static_cast<uint32_t>(emitted.size());
}

uint32_t GuavaJoltContextImpl::copy_contact_events(GuavaJoltContactEvent* out_events, size_t event_capacity) const {
    return events.contact_listener.copy_events(out_events, event_capacity);
}

uint32_t GuavaJoltContextImpl::drain_joint_break_events(
    GuavaJoltJointBreakEvent* out_events, size_t event_capacity) {
    const uint32_t total = static_cast<uint32_t>(events.joint_break_events.size());
    const size_t count = std::min(event_capacity, events.joint_break_events.size());
    if (out_events) {
        for (size_t index = 0; index < count; ++index) out_events[index] = events.joint_break_events[index];
    }
    events.joint_break_events.clear();
    return total;
}