#include "particle_simulation_common.slang"
struct ParticleStateMaintenanceUniforms { uint4 params; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleStateMaintenanceUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] StructuredBuffer<ParticleSimState> source_particles : register(t1,space0);
[[vk::binding(2,0)]] RWStructuredBuffer<ParticleSimState> compact_particles : register(u2,space0);
[[vk::binding(3,0)]] RWStructuredBuffer<ParticleSimMetadata> metadata : register(u3,space0);
groupshared uint prefix[256];
groupshared uint output_base;
// One physical group scans tiles in source order. Atomic scheduling must not
// decide which particles survive the render budget or equal-key sort ties.
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleCompact(uint3 lane : SV_GroupThreadID) {
    uint tid = lane.x;
    if (tid == 0) output_base = 0;
    GroupMemoryBarrierWithGroupSync();
    for (uint base = 0; base < uniforms.params.x; base += particleWorkgroupSize) {
        uint index = base+tid;
        ParticleSimState particle = (ParticleSimState)0;
        if (index < uniforms.params.x) particle = source_particles[index];
        bool alive = index < uniforms.params.x && particle.position_lifetime.w > 0 && particle.velocity_age.w < particle.position_lifetime.w;
        prefix[tid] = alive ? 1 : 0;
        GroupMemoryBarrierWithGroupSync();
        for (uint offset = 1; offset < particleWorkgroupSize; offset *= 2) {
            uint sum = prefix[tid];
            if (tid >= offset) sum += prefix[tid-offset];
            GroupMemoryBarrierWithGroupSync();
            prefix[tid] = sum;
            GroupMemoryBarrierWithGroupSync();
        }
        if (alive) {
            uint slot = output_base+prefix[tid]-1;
            if (slot < uniforms.params.y) compact_particles[slot] = particle;
        }
        GroupMemoryBarrierWithGroupSync();
        if (tid == 0) output_base += prefix[particleWorkgroupSize-1];
        GroupMemoryBarrierWithGroupSync();
    }
    if (tid == 0) metadata[0].compacted_count = output_base;
}
