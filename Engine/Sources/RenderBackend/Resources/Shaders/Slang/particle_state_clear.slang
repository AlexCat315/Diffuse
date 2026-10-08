#include "particle_simulation_common.slang"
struct ParticleStateMaintenanceUniforms { uint4 params; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleStateMaintenanceUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] RWStructuredBuffer<ParticleSimState> particles : register(u1,space0);
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleClear(uint3 gid : SV_DispatchThreadID) {
    if (gid.x < uniforms.params.y) particles[gid.x] = (ParticleSimState)0;
}
