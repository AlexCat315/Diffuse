#include "particle_sort_common.slang"
struct ParticleSortBitonicUniforms { uint4 params; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleSortBitonicUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] RWStructuredBuffer<ParticleSortItem> sort_items : register(u1,space0);
bool particle_sort_item_less(ParticleSortItem lhs,ParticleSortItem rhs) {
    return abs(lhs.key-rhs.key) <= 0.000001 ? lhs.index < rhs.index : lhs.key < rhs.key;
}
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleSortBitonic(uint3 gid : SV_DispatchThreadID) {
    uint index = gid.x, count = uniforms.params.x, k = uniforms.params.y, j = uniforms.params.z;
    if (index >= count) return;
    uint partner = index^j;
    if (partner <= index || partner >= count) return;
    ParticleSortItem left = sort_items[index], right = sort_items[partner];
    bool ascending = (index&k) == 0;
    bool should_swap = ascending ? particle_sort_item_less(right,left) : particle_sort_item_less(left,right);
    if (should_swap) { sort_items[index] = right; sort_items[partner] = left; }
}
