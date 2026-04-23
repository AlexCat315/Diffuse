#ifndef GUAVA_JOLT_BRIDGE_H
#define GUAVA_JOLT_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaJoltContextImpl* GuavaJoltContext;

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
    float linear_velocity_x;
    float linear_velocity_y;
    float linear_velocity_z;
    float angular_velocity_x;
    float angular_velocity_y;
    float angular_velocity_z;
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
} GuavaJoltConstraintDesc;

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

typedef struct GuavaJoltStepStats {
    uint32_t body_count;
    uint32_t constraint_count;
    uint32_t contact_count;
    uint32_t state_count;
    uint8_t success;
    uint8_t reserved0;
    uint16_t reserved1;
} GuavaJoltStepStats;

GuavaJoltContext guava_jolt_context_create(void);
void guava_jolt_context_destroy(GuavaJoltContext context);
void guava_jolt_context_reset(GuavaJoltContext context);
bool guava_jolt_context_prepare(GuavaJoltContext context,
                                const GuavaJoltBodyDesc* bodies,
                                size_t body_count,
                                const GuavaJoltConstraintDesc* constraints,
                                size_t constraint_count,
                                GuavaJoltPrepareStats* out_stats);
bool guava_jolt_context_step(GuavaJoltContext context,
                             const GuavaJoltStepConfig* config,
                             GuavaJoltBodyState* states,
                             size_t state_count,
                             GuavaJoltStepStats* out_stats);

#ifdef __cplusplus
}
#endif

#endif