#include "particle_common.slang"
struct ParticleCullUniforms { column_major float4x4 viewProj; uint4 params; };
struct ParticleCullBatch { uint sourceStart; uint sourceCount; uint outputStart; uint padding; };
struct ParticleIndirectDrawArgs { uint vertexCount; uint instanceCount; uint firstVertex; uint firstInstance; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleCullUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] StructuredBuffer<ParticleInstance> sourceParticles : register(t1,space0);
[[vk::binding(2,0)]] StructuredBuffer<ParticleCullBatch> batches : register(t2,space0);
[[vk::binding(3,0)]] RWStructuredBuffer<ParticleInstance> visibleParticles : register(u3,space0);
[[vk::binding(4,0)]] RWStructuredBuffer<ParticleIndirectDrawArgs> drawArgs : register(u4,space0);
groupshared uint visibleFlags[64];
groupshared uint visibleBase;
bool particleVisible(ParticleInstance p) {
    if (p.positionSize.w <= 0 || p.color.w <= 0) return false;
    float4 clip = mul(uniforms.viewProj,float4(p.positionSize.xyz,1));
    if (abs(clip.w) <= 0.0001) return false;
    float3 ndc = clip.xyz/clip.w;
    float radius = max(p.positionSize.w*max(p.axisStretch.w,1.0),0.0);
    float padding = clamp(radius*0.25,0.0,0.25);
    return ndc.x >= -1-padding && ndc.x <= 1+padding && ndc.y >= -1-padding && ndc.y <= 1+padding;
}
[shader("compute")]
[numthreads(64,1,1)]
void particleCull(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
    if (group.x >= uniforms.params.x) return;
    ParticleCullBatch batch = batches[group.x];
    if (local.x == 0) visibleBase = 0;
    GroupMemoryBarrierWithGroupSync();
    for (uint tile = 0; tile < batch.sourceCount; tile += 64) {
        uint sourceOffset = tile+local.x;
        uint visible = 0;
        if (sourceOffset < batch.sourceCount) visible = particleVisible(sourceParticles[batch.sourceStart+sourceOffset]) ? 1 : 0;
        visibleFlags[local.x] = visible;
        GroupMemoryBarrierWithGroupSync();
        if (visible == 1) {
            uint prefix = 0;
            for (uint i=0; i<local.x; ++i) prefix += visibleFlags[i];
            visibleParticles[batch.outputStart+visibleBase+prefix] = sourceParticles[batch.sourceStart+sourceOffset];
        }
        GroupMemoryBarrierWithGroupSync();
        if (local.x == 0) {
            uint count = 0;
            for (uint i=0; i<64; ++i) count += visibleFlags[i];
            visibleBase += count;
        }
        GroupMemoryBarrierWithGroupSync();
    }
    if (local.x == 0) {
        ParticleIndirectDrawArgs args;
        args.vertexCount = 6; args.instanceCount = visibleBase;
        args.firstVertex = 0; args.firstInstance = batch.outputStart;
        drawArgs[group.x] = args;
    }
}
