#include "particle_simulation_common.slang"
[[vk::binding(0,0)]] RWStructuredBuffer<ParticleSimMetadata> metadata : register(u0,space0);
[shader("compute")]
[numthreads(1,1,1)]
void particleFinalize(uint3 gid : SV_DispatchThreadID) {
    if (gid.x == 0) metadata[0].append_cursor = metadata[0].compacted_count;
}
