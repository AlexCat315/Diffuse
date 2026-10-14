#include "Internal.hpp"

using namespace jolt;

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
    out_layout->joint_break_event_size = static_cast<uint32_t>(sizeof(GuavaJoltJointBreakEvent));
    out_layout->context_config_size = static_cast<uint32_t>(sizeof(GuavaJoltContextConfig));
    out_layout->soft_body_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltSoftBodyDesc));
    out_layout->soft_body_state_size = static_cast<uint32_t>(sizeof(GuavaJoltSoftBodyState));
    out_layout->soft_body_sync_stats_size = static_cast<uint32_t>(sizeof(GuavaJoltSoftBodySyncStats));
    return true;
}

bool guava_jolt_bridge_get_vehicle_abi_layout(GuavaJoltVehicleABILayout* out_layout) {
    if (!out_layout || out_layout->struct_size != sizeof(GuavaJoltVehicleABILayout)) return false;
    out_layout->abi_version = GUAVA_JOLT_ABI_VERSION;
    out_layout->vehicle_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleDesc));
    out_layout->wheel_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleWheelDesc));
    out_layout->differential_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleDifferentialDesc));
    out_layout->anti_roll_bar_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleAntiRollBarDesc));
    out_layout->track_desc_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleTrackDesc));
    out_layout->command_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleCommand));
    out_layout->state_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleState));
    out_layout->wheel_state_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleWheelState));
    out_layout->sync_stats_size = static_cast<uint32_t>(sizeof(GuavaJoltVehicleSyncStats));
    return true;
}

GuavaJoltContext guava_jolt_context_create(void) {
    GuavaJoltContextConfig config{};
    config.struct_size = static_cast<uint32_t>(sizeof(GuavaJoltContextConfig));
    config.max_bodies = 65536;
    config.body_mutex_count = 0;
    config.max_body_pairs = 65536;
    config.max_contact_constraints = 10240;
    config.worker_thread_count = 0;
    config.temp_allocator_bytes = 10u * 1024u * 1024u;
    return guava_jolt_context_create_with_config(&config);
}

GuavaJoltContext guava_jolt_context_create_with_config(const GuavaJoltContextConfig* config) {
    const bool body_mutex_count_is_valid = config
        && (config->body_mutex_count == 0
            || (config->body_mutex_count & (config->body_mutex_count - 1)) == 0);
    if (!config
        || config->struct_size != sizeof(GuavaJoltContextConfig)
        || config->max_bodies == 0
        || config->max_bodies > JPH::PhysicsSystem::cMaxBodiesLimit
        || !body_mutex_count_is_valid
        || config->max_body_pairs == 0
        || config->max_body_pairs > JPH::PhysicsSystem::cMaxBodyPairsLimit
        || config->max_contact_constraints == 0
        || config->max_contact_constraints > JPH::PhysicsSystem::cMaxContactConstraintsLimit
        || config->worker_thread_count > 1024
        || config->temp_allocator_bytes < 1024u * 1024u
        || config->temp_allocator_bytes > UINT32_MAX) {
        return nullptr;
    }
    ensure_jolt_initialized();
    return new (std::nothrow) GuavaJoltContextImpl(*config);
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
                            nullptr, 0, nullptr, 0, nullptr, 0, false, out_stats);
}

bool guava_jolt_context_prepare_with_meshes(GuavaJoltContext context,
                                            const GuavaJoltBodyDesc* bodies, size_t body_count,
                                            const GuavaJoltConstraintDesc* constraints,
                                            size_t constraint_count,
                                            const GuavaJoltMeshGeometry* meshes, size_t mesh_count,
                                            GuavaJoltPrepareStats* out_stats) {
    if (!context || !out_stats) return false;
    return context->prepare(bodies, body_count, constraints, constraint_count,
                            meshes, mesh_count, nullptr, 0, nullptr, 0, false, out_stats);
}

bool guava_jolt_context_apply_sync_events(
    GuavaJoltContext context,
    const GuavaJoltBodyDesc* body_upserts, size_t body_upsert_count,
    const uint64_t* body_removals, size_t body_removal_count,
    const GuavaJoltConstraintDesc* constraint_upserts, size_t constraint_upsert_count,
    const uint64_t* constraint_removals, size_t constraint_removal_count,
    const GuavaJoltMeshGeometry* meshes, size_t mesh_count,
    GuavaJoltPrepareStats* out_stats) {
    if (!context || !out_stats) return false;
    return context->prepare(
        body_upserts, body_upsert_count,
        constraint_upserts, constraint_upsert_count,
        meshes, mesh_count,
        body_removals, body_removal_count,
        constraint_removals, constraint_removal_count,
        true,
        out_stats);
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

bool guava_jolt_context_sync_vehicles(
    GuavaJoltContext context,
    const GuavaJoltVehicleDesc* upserts,
    size_t upsert_count,
    const uint64_t* removals,
    size_t removal_count,
    bool full_snapshot,
    GuavaJoltVehicleSyncStats* out_stats) {
    if (!context) return false;
    return context->sync_vehicles(
        upserts, upsert_count, removals, removal_count, full_snapshot, out_stats);
}

bool guava_jolt_context_set_vehicle_commands(
    GuavaJoltContext context,
    const GuavaJoltVehicleCommand* commands,
    size_t command_count) {
    if (!context) return false;
    return context->set_vehicle_commands(commands, command_count);
}

uint32_t guava_jolt_context_copy_vehicle_states(
    GuavaJoltContext context,
    GuavaJoltVehicleState* out_states,
    size_t state_capacity,
    GuavaJoltVehicleWheelState* out_wheel_states,
    size_t wheel_state_capacity,
    uint32_t* out_wheel_state_count) {
    if (!context) return 0;
    return context->copy_vehicle_states(
        out_states, state_capacity, out_wheel_states, wheel_state_capacity,
        out_wheel_state_count);
}

bool guava_jolt_context_sync_soft_bodies(
    GuavaJoltContext context,
    const GuavaJoltSoftBodyDesc* upserts,
    size_t upsert_count,
    const uint64_t* removals,
    size_t removal_count,
    bool full_snapshot,
    GuavaJoltSoftBodySyncStats* out_stats) {
    if (!context) return false;
    return context->sync_soft_bodies(
        upserts, upsert_count, removals, removal_count, full_snapshot, out_stats);
}

uint32_t guava_jolt_context_copy_soft_body_states(
    GuavaJoltContext context,
    GuavaJoltSoftBodyState* out_states,
    size_t state_capacity,
    float* out_positions_xyz,
    size_t vertex_capacity,
    uint32_t* out_vertex_count) {
    if (!context) return 0;
    return context->copy_soft_body_states(
        out_states, state_capacity, out_positions_xyz, vertex_capacity,
        out_vertex_count);
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

uint32_t guava_jolt_context_drain_joint_break_events(GuavaJoltContext context,
                                                     GuavaJoltJointBreakEvent* out_events,
                                                     size_t event_capacity) {
    if (!context) return 0;
    if (event_capacity > 0 && !out_events) return 0;
    return context->drain_joint_break_events(out_events, event_capacity);
}

}  // extern "C"
