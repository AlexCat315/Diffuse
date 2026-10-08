#include "particle_simulation_common.slang"
[[vk::binding(0,0)]] RWStructuredBuffer<ParticleSimMetadata> metadata : register(u0,space0);
[shader("compute")]
[numthreads(1,1,1)]
void particleMetadataReset(uint3 gid : SV_DispatchThreadID) {
    if (gid.x != 0) return;
    // This serial pass preserves the preceding frame's resident append cursor.
    uint cursor = metadata[0].append_cursor;
    ParticleSimMetadata reset = (ParticleSimMetadata)0; reset.append_cursor = cursor;
    metadata[0] = reset;
}
