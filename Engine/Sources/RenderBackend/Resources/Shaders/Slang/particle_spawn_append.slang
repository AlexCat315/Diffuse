#include "particle_simulation_common.slang"
struct ParticleSpawnUniforms { uint4 params; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleSpawnUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] StructuredBuffer<ParticleSimState> spawn_particles : register(t1,space0);
[[vk::binding(2,0)]] RWStructuredBuffer<ParticleSimState> particles : register(u2,space0);
[[vk::binding(3,0)]] RWStructuredBuffer<ParticleSimMetadata> metadata : register(u3,space0);
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleSpawn(uint3 gid : SV_DispatchThreadID) {
    if (gid.x >= uniforms.params.x) return;
    uint slot, ignored;
    // The cursor stays immutable during this dispatch; finalize publishes the
    // compacted cursor afterwards. Source order is independent of scheduling.
    slot = metadata[0].append_cursor+gid.x;
    if (slot >= uniforms.params.y) { InterlockedAdd(metadata[0].dropped_spawn_count,1,ignored); return; }
    particles[slot] = spawn_particles[gid.x];
    InterlockedAdd(metadata[0].spawned_count,1,ignored);
}
