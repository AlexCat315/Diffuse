#include <stdio.h>
#include <stddef.h>
#include <stdint.h>

struct GuavaJoltBodyDesc {
  uint64_t entity_id;
  uint32_t motion_type;
  uint32_t flags;
  float mass;
  float gravity_scale;
  float linear_damping;
  float max_linear_speed;
  float position[3];
  float rotation[4];
  float linear_velocity[3];
  float box_half_extents[3];
  float box_center[3];
  float sphere_radius;
  float sphere_center[3];
  float mesh_half_extents[3];
  float mesh_center[3];
  uint32_t layer_id;
  uint32_t layer_group;
};

int main() {
    printf("Size: %zu\n", sizeof(GuavaJoltBodyDesc));
    printf("Offset of linear_velocity: %zu\n", offsetof(GuavaJoltBodyDesc, linear_velocity));
    printf("Offset of position: %zu\n", offsetof(GuavaJoltBodyDesc, position));
    return 0;
}
