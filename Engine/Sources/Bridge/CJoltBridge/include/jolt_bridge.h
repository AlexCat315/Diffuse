#ifndef GUAVA_JOLT_BRIDGE_H
#define GUAVA_JOLT_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaJoltContextImpl* GuavaJoltContext;

#define GUAVA_JOLT_ABI_VERSION 2u

typedef enum GuavaJoltErrorCode {
    GUAVA_JOLT_ERROR_NONE = 0,
    GUAVA_JOLT_ERROR_ABI_MISMATCH = 1,
    GUAVA_JOLT_ERROR_INVALID_ARGUMENT = 2,
    GUAVA_JOLT_ERROR_INVALID_SHAPE = 3,
    GUAVA_JOLT_ERROR_BODY_CREATION_FAILED = 4,
    GUAVA_JOLT_ERROR_UPDATE_FAILED = 5
} GuavaJoltErrorCode;

typedef struct GuavaJoltContextConfig {
    uint32_t struct_size;
    uint32_t max_bodies;
    uint32_t body_mutex_count;
    uint32_t max_body_pairs;
    uint32_t max_contact_constraints;
    uint32_t worker_thread_count; /* zero selects hardware concurrency minus one */
    uint64_t temp_allocator_bytes;
} GuavaJoltContextConfig;

typedef struct GuavaJoltABILayout {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t body_desc_size;
    uint32_t constraint_desc_size;
    uint32_t step_config_size;
    uint32_t body_state_size;
    uint32_t contact_event_size;
    uint32_t character_desc_size;
    uint32_t character_command_size;
    uint32_t character_state_size;
    uint32_t shape_instance_size;
    uint32_t joint_break_event_size;
    uint32_t context_config_size;
} GuavaJoltABILayout;

typedef struct GuavaJoltShapeInstance {
    uint8_t shape_type; /* 0 box, 1 sphere, 2 capsule, 3 cylinder, 4 mesh, 5 convex, 6 height field */
    uint8_t reserved0;
    uint16_t reserved1;
    float position_x;
    float position_y;
    float position_z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float scale_x;
    float scale_y;
    float scale_z;
    float half_extent_x;
    float half_extent_y;
    float half_extent_z;
    float radius;
    float half_height;
} GuavaJoltShapeInstance;

typedef struct GuavaJoltBodyDesc {
    uint64_t entity_id;
    uint32_t motion_type;
    uint32_t flags;
    float position_x;
    float position_y;
    float position_z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float shape_center_x;
    float shape_center_y;
    float shape_center_z;
    float shape_scale_x;
    float shape_scale_y;
    float shape_scale_z;
    float linear_velocity_x;
    float linear_velocity_y;
    float linear_velocity_z;
    float angular_velocity_x;
    float angular_velocity_y;
    float angular_velocity_z;
    float accumulated_force_x;
    float accumulated_force_y;
    float accumulated_force_z;
    float accumulated_torque_x;
    float accumulated_torque_y;
    float accumulated_torque_z;
    float accumulated_linear_impulse_x;
    float accumulated_linear_impulse_y;
    float accumulated_linear_impulse_z;
    float accumulated_angular_impulse_x;
    float accumulated_angular_impulse_y;
    float accumulated_angular_impulse_z;
    float box_half_extent_x;
    float box_half_extent_y;
    float box_half_extent_z;
    float sphere_radius;
    float capsule_radius;
    float capsule_half_height;
    float mass;
    float gravity_scale;
    float linear_damping;
    float angular_damping;
    uint8_t is_sleeping;
    uint8_t reserved0;
    uint16_t reserved1;
    uint16_t layer_id;
    uint16_t layer_mask;
    float friction;
    float restitution;
    float density;
    const GuavaJoltShapeInstance* shape_instances;
    uint32_t shape_instance_count;
    uint32_t shape_instances_reserved;
    uint8_t mass_mode; /* 0 authored mass, 1 shape density */
    uint8_t motion_quality; /* 0 discrete, 1 linear cast */
    uint8_t allowed_dofs;
    uint8_t has_center_of_mass_override;
    uint8_t has_inertia_override;
    uint8_t has_kinematic_target;
    uint16_t rigid_body_reserved;
    float max_linear_velocity;
    float max_angular_velocity;
    float center_of_mass_x;
    float center_of_mass_y;
    float center_of_mass_z;
    float inertia_x;
    float inertia_y;
    float inertia_z;
    float target_position_x;
    float target_position_y;
    float target_position_z;
    float target_rotation_x;
    float target_rotation_y;
    float target_rotation_z;
    float target_rotation_w;
} GuavaJoltBodyDesc;

typedef struct GuavaJoltConstraintDesc {
    uint64_t entity_id;
    uint64_t entity_a;
    uint64_t entity_b;
    uint8_t constraint_type;
    uint8_t is_enabled;
    uint16_t reserved;
    float pivot_a_x;
    float pivot_a_y;
    float pivot_a_z;
    float pivot_b_x;
    float pivot_b_y;
    float pivot_b_z;
    float axis_a_x;
    float axis_a_y;
    float axis_a_z;
    float axis_b_x;
    float axis_b_y;
    float axis_b_z;
    float min_limit;
    float max_limit;
    float break_force;
    float break_torque;
    float spring_frequency;
    float spring_damping;
    uint8_t motor_mode;
    uint8_t angular_motor_mode;
    uint16_t joint_reserved;
    float motor_target_position;
    float motor_target_velocity;
    float motor_max_force;
    float angular_motor_target_position;
    float angular_motor_target_velocity;
    float angular_motor_max_force;
    float half_cone_angle;
    float linear_min_x;
    float linear_min_y;
    float linear_min_z;
    float linear_max_x;
    float linear_max_y;
    float linear_max_z;
    float angular_min_x;
    float angular_min_y;
    float angular_min_z;
    float angular_max_x;
    float angular_max_y;
    float angular_max_z;
} GuavaJoltConstraintDesc;

typedef struct GuavaJoltMeshGeometry {
    uint64_t entity_id;
    uint64_t geometry_revision;
    const float* vertices;
    uint32_t vertex_count;
    const uint32_t* indices;
    uint32_t index_count;
} GuavaJoltMeshGeometry;

typedef struct GuavaJoltPrepareStats {
    uint32_t synchronized_bodies;
    uint32_t synchronized_constraints;
    uint32_t removed_bodies;
    uint32_t removed_constraints;
} GuavaJoltPrepareStats;

typedef struct GuavaJoltStepConfig {
    float delta_seconds;
    float gravity_x;
    float gravity_y;
    float gravity_z;
    uint32_t collision_steps;
    uint8_t allow_sleep;
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltStepConfig;

typedef struct GuavaJoltBodyState {
    uint64_t entity_id;
    float position_x;
    float position_y;
    float position_z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float linear_velocity_x;
    float linear_velocity_y;
    float linear_velocity_z;
    float angular_velocity_x;
    float angular_velocity_y;
    float angular_velocity_z;
    uint8_t is_sleeping;
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltBodyState;

typedef struct GuavaJoltCharacterDesc {
    uint64_t entity_id;
    float position_x;
    float position_y;
    float position_z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float center_x;
    float center_y;
    float center_z;
    float radius;
    float standing_half_height;
    float crouching_half_height;
    float max_slope_radians;
    float step_height;
    float skin_width;
    float mass;
    float max_strength;
    float gravity_scale;
    uint16_t layer_id;
    uint16_t layer_mask;
} GuavaJoltCharacterDesc;

typedef struct GuavaJoltCharacterCommand {
    uint64_t entity_id;
    float desired_velocity_x;
    float desired_velocity_y;
    float desired_velocity_z;
    float jump_speed;
    uint8_t jump_requested;
    uint8_t stance; /* 0 standing, 1 crouching */
    uint16_t reserved;
} GuavaJoltCharacterCommand;

typedef struct GuavaJoltCharacterState {
    uint64_t entity_id;
    float position_x;
    float position_y;
    float position_z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float linear_velocity_x;
    float linear_velocity_y;
    float linear_velocity_z;
    float ground_normal_x;
    float ground_normal_y;
    float ground_normal_z;
    float ground_velocity_x;
    float ground_velocity_y;
    float ground_velocity_z;
    uint64_t ground_entity;
    uint8_t has_ground_entity;
    uint8_t ground_state; /* 0 ground, 1 steep, 2 unsupported, 3 air */
    uint8_t stance;
    uint8_t reserved;
} GuavaJoltCharacterState;

typedef struct GuavaJoltStepStats {
    uint32_t body_count;
    uint32_t constraint_count;
    uint32_t contact_count;
    uint32_t state_count;
    uint8_t success;
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltStepStats;

typedef struct GuavaJoltQueryFilter {
    uint64_t exclude_entity;
    uint8_t has_exclude_entity;
    uint8_t include_triggers;
    uint8_t has_layer_id;
    uint8_t reserved0;
    uint16_t layer_id;
    uint16_t layer_mask;
} GuavaJoltQueryFilter;

typedef struct GuavaJoltRaycastQuery {
    float origin_x;
    float origin_y;
    float origin_z;
    float direction_x;
    float direction_y;
    float direction_z;
    float max_distance;
} GuavaJoltRaycastQuery;

typedef struct GuavaJoltRaycastHit {
    uint64_t entity_id;
    float distance;
    float position_x;
    float position_y;
    float position_z;
    float normal_x;
    float normal_y;
    float normal_z;
    float bounds_min_x;
    float bounds_min_y;
    float bounds_min_z;
    float bounds_max_x;
    float bounds_max_y;
    float bounds_max_z;
    uint32_t sub_shape_id;
    uint8_t is_trigger;
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltRaycastHit;

typedef struct GuavaJoltOverlapAABBQuery {
    float bounds_min_x;
    float bounds_min_y;
    float bounds_min_z;
    float bounds_max_x;
    float bounds_max_y;
    float bounds_max_z;
    uint32_t max_results;
} GuavaJoltOverlapAABBQuery;

typedef struct GuavaJoltOverlapHit {
    uint64_t entity_id;
    float bounds_min_x;
    float bounds_min_y;
    float bounds_min_z;
    float bounds_max_x;
    float bounds_max_y;
    float bounds_max_z;
    uint32_t sub_shape_id;
    uint8_t is_trigger;
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltOverlapHit;

typedef struct GuavaJoltOverlapShapeQuery {
    uint8_t shape_type; /* 0 box, 1 sphere, 2 capsule */
    uint8_t reserved0;
    uint16_t reserved1;
    float position_x;
    float position_y;
    float position_z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float box_half_extent_x;
    float box_half_extent_y;
    float box_half_extent_z;
    float sphere_radius;
    float capsule_radius;
    float capsule_half_height;
    uint32_t max_results;
} GuavaJoltOverlapShapeQuery;

typedef struct GuavaJoltSweepAABBQuery {
    float bounds_min_x;
    float bounds_min_y;
    float bounds_min_z;
    float bounds_max_x;
    float bounds_max_y;
    float bounds_max_z;
    float translation_x;
    float translation_y;
    float translation_z;
} GuavaJoltSweepAABBQuery;

typedef struct GuavaJoltSweepShapeQuery {
    uint8_t shape_type; /* 0 box, 1 sphere, 2 capsule */
    uint8_t reserved0;
    uint16_t reserved1;
    float position_x;
    float position_y;
    float position_z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float box_half_extent_x;
    float box_half_extent_y;
    float box_half_extent_z;
    float sphere_radius;
    float capsule_radius;
    float capsule_half_height;
    float translation_x;
    float translation_y;
    float translation_z;
} GuavaJoltSweepShapeQuery;

typedef struct GuavaJoltSweepHit {
    uint64_t entity_id;
    float fraction;
    float distance;
    float position_x;
    float position_y;
    float position_z;
    float normal_x;
    float normal_y;
    float normal_z;
    float bounds_min_x;
    float bounds_min_y;
    float bounds_min_z;
    float bounds_max_x;
    float bounds_max_y;
    float bounds_max_z;
    uint32_t sub_shape_id;
    uint8_t is_trigger;
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltSweepHit;

typedef struct GuavaJoltTriggerEvent {
    uint64_t trigger_entity;
    uint64_t other_entity;
    uint8_t kind; /* 0 enter, 1 exit, 2 active */
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltTriggerEvent;

typedef struct GuavaJoltContactEvent {
    uint64_t entity_a;
    uint64_t entity_b;
    uint8_t kind; /* 0 began, 1 persisted, 2 ended */
    uint8_t reserved0;
    uint16_t reserved1;
    uint32_t sub_shape_id_a;
    uint32_t sub_shape_id_b;
    float position_x;
    float position_y;
    float position_z;
    float normal_x;
    float normal_y;
    float normal_z;
    float penetration_depth;
    float relative_velocity_x;
    float relative_velocity_y;
    float relative_velocity_z;
    float impulse;
} GuavaJoltContactEvent;

typedef struct GuavaJoltJointBreakEvent {
    uint64_t joint_entity;
    uint64_t entity_a;
    uint64_t entity_b;
    float force;
    float torque;
} GuavaJoltJointBreakEvent;

uint32_t guava_jolt_bridge_abi_version(void);
bool guava_jolt_bridge_get_abi_layout(GuavaJoltABILayout* out_layout);
GuavaJoltContext guava_jolt_context_create(void);
GuavaJoltContext guava_jolt_context_create_with_config(const GuavaJoltContextConfig* config);
uint32_t guava_jolt_context_last_error(GuavaJoltContext context);
void guava_jolt_context_destroy(GuavaJoltContext context);
void guava_jolt_context_reset(GuavaJoltContext context);
bool guava_jolt_context_prepare(GuavaJoltContext context,
                                const GuavaJoltBodyDesc* bodies,
                                size_t body_count,
                                const GuavaJoltConstraintDesc* constraints,
                                size_t constraint_count,
                                GuavaJoltPrepareStats* out_stats);
bool guava_jolt_context_prepare_with_meshes(
    GuavaJoltContext context,
    const GuavaJoltBodyDesc* bodies,
    size_t body_count,
    const GuavaJoltConstraintDesc* constraints,
    size_t constraint_count,
    const GuavaJoltMeshGeometry* meshes,
    size_t mesh_count,
    GuavaJoltPrepareStats* out_stats);
bool guava_jolt_context_step(GuavaJoltContext context,
                             const GuavaJoltStepConfig* config,
                             GuavaJoltBodyState* states,
                             size_t state_count,
                             GuavaJoltStepStats* out_stats);
bool guava_jolt_context_sync_characters(GuavaJoltContext context,
                                        const GuavaJoltCharacterDesc* characters,
                                        size_t character_count);
uint32_t guava_jolt_context_step_characters(GuavaJoltContext context,
                                            const GuavaJoltStepConfig* config,
                                            const GuavaJoltCharacterCommand* commands,
                                            size_t command_count,
                                            GuavaJoltCharacterState* out_states,
                                            size_t state_capacity);
bool guava_jolt_context_raycast(GuavaJoltContext context,
                                const GuavaJoltRaycastQuery* query,
                                const GuavaJoltQueryFilter* filter,
                                GuavaJoltRaycastHit* out_hit);
uint32_t guava_jolt_context_raycast_all(GuavaJoltContext context,
                                        const GuavaJoltRaycastQuery* query,
                                        const GuavaJoltQueryFilter* filter,
                                        GuavaJoltRaycastHit* out_hits,
                                        size_t hit_capacity);
uint32_t guava_jolt_context_overlap_aabb(GuavaJoltContext context,
                                         const GuavaJoltOverlapAABBQuery* query,
                                         const GuavaJoltQueryFilter* filter,
                                         GuavaJoltOverlapHit* out_hits,
                                         size_t hit_capacity);
uint32_t guava_jolt_context_overlap_shape(GuavaJoltContext context,
                                          const GuavaJoltOverlapShapeQuery* query,
                                          const GuavaJoltQueryFilter* filter,
                                          GuavaJoltOverlapHit* out_hits,
                                          size_t hit_capacity);
bool guava_jolt_context_sweep_aabb(GuavaJoltContext context,
                                   const GuavaJoltSweepAABBQuery* query,
                                   const GuavaJoltQueryFilter* filter,
                                   GuavaJoltSweepHit* out_hit);
bool guava_jolt_context_sweep_shape(GuavaJoltContext context,
                                    const GuavaJoltSweepShapeQuery* query,
                                    const GuavaJoltQueryFilter* filter,
                                    GuavaJoltSweepHit* out_hit);
uint32_t guava_jolt_context_sweep_shape_all(GuavaJoltContext context,
                                            const GuavaJoltSweepShapeQuery* query,
                                            const GuavaJoltQueryFilter* filter,
                                            GuavaJoltSweepHit* out_hits,
                                            size_t hit_capacity);
uint32_t guava_jolt_context_detect_triggers(GuavaJoltContext context,
                                            GuavaJoltTriggerEvent* out_events,
                                            size_t event_capacity);
uint32_t guava_jolt_context_copy_contact_events(GuavaJoltContext context,
                                                GuavaJoltContactEvent* out_events,
                                                size_t event_capacity);
uint32_t guava_jolt_context_drain_joint_break_events(GuavaJoltContext context,
                                                     GuavaJoltJointBreakEvent* out_events,
                                                     size_t event_capacity);

#ifdef __cplusplus
}
#endif

#endif
