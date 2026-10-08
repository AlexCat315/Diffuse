#include "particle_simulation_common.slang"
struct ParticleStateMaintenanceUniforms { uint4 params; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleStateMaintenanceUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] StructuredBuffer<ParticleSimState> source_particles : register(t1,space0);
[[vk::binding(2,0)]] RWStructuredBuffer<ParticleSimState> compact_particles : register(u2,space0);
[[vk::binding(3,0)]] RWStructuredBuffer<ParticleSimMetadata> metadata : register(u3,space0);
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleCompact(uint3 gid : SV_DispatchThreadID) {
    if (gid.x >= uniforms.params.x) return;
    ParticleSimState particle = source_particles[gid.x];
    if (particle.position_lifetime.w <= 0 || particle.velocity_age.w >= particle.position_lifetime.w) return;
    uint slot; InterlockedAdd(metadata[0].compacted_count,1,slot);
    if (slot < uniforms.params.y) compact_particles[slot] = particle;
}
