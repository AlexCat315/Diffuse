#include "particle_sort_common.slang"
struct ParticleSortPrepareUniforms { column_major float4x4 world_transform; float4 params; float4 sort_params; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleSortPrepareUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] StructuredBuffer<ParticleSimState> sim_particles : register(t1,space0);
[[vk::binding(2,0)]] RWStructuredBuffer<ParticleSortItem> sort_items : register(u2,space0);
float particle_sort_key(ParticleSimState particle,uint mode) {
    if (particle.position_lifetime.w <= 0 || particle.velocity_age.w >= particle.position_lifetime.w) return 3.402823e38;
    if (mode == 2) return -particle.velocity_age.w;
    if (mode == 3) return particle.velocity_age.w;
    float4 world_position = mul(uniforms.world_transform,float4(particle.position_lifetime.xyz,1));
    float inv_w = abs(world_position.w) > 0.0001 ? 1/world_position.w : 1;
    float3 to_camera = world_position.xyz*inv_w-uniforms.sort_params.xyz;
    float distance_squared = dot(to_camera,to_camera);
    return mode == 1 ? distance_squared : -distance_squared;
}
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleSortPrepare(uint3 gid : SV_DispatchThreadID) {
    uint local_index = gid.x, count = uint(uniforms.params.x), start = uint(uniforms.params.y), capacity = uint(uniforms.params.w);
    if (local_index >= capacity) return;
    ParticleSortItem item = {3.402823e38,0xffffffff,0,0};
    if (local_index < count) { item.key = particle_sort_key(sim_particles[start+local_index],uint(uniforms.params.z)); item.index = local_index; }
    sort_items[local_index] = item;
}
