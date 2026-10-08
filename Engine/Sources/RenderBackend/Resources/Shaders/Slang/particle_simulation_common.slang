struct ParticleSimState {
    float4 position_lifetime;
    float4 velocity_age;
    float4 size_rotation;
    float4 color;
    uint4 params;
};
struct ParticleSimMetadata {
    uint alive_count;
    uint expired_count;
    uint collision_count;
    uint spawned_count;
    uint dropped_spawn_count;
    uint append_cursor;
    uint compacted_count;
    uint event_count;
};
struct ParticleSimEvent { float4 position_lifetime; float4 velocity_age; uint4 params; };
#ifdef PARTICLE_WORKGROUP_SIZE
static const uint particleWorkgroupSize = PARTICLE_WORKGROUP_SIZE;
#else
[vk::constant_id(0)] const uint particleWorkgroupSize = 64;
#endif
