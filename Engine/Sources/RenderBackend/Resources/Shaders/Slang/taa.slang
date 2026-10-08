#include "post_common.slang"
[[vk::binding(3,0)]] ConstantBuffer<float4> effect : register(b3, space0);
float3 clipAABB(float3 color, float3 lo, float3 hi) {
    float3 center = (hi+lo)*0.5, extent = (hi-lo)*0.5;
    float3 offset = color-center, ts = abs(extent)/max(abs(offset),float3(0.0001));
    float t = min(1,min(ts.x,min(ts.y,ts.z)));
    return center+offset*t;
}
[shader("fragment")]
float4 postFragment(PostVertex input) : SV_Target0 {
    float2 uv = texUV(input.uv);
    float3 current = sceneColor(uv);
    if (effect.w < 0.5) return float4(current,1);
    float3 history = secondaryTexture.SampleLevel(postSampler,uv,0).rgb;
    float3 lo = current, hi = current;
    for (int y=-1; y<=1; ++y) for (int x=-1; x<=1; ++x) {
        float3 color = sceneColor(uv+float2(x,y)*effect.yz);
        lo = min(lo,color); hi = max(hi,color);
    }
    return float4(lerp(current,clipAABB(history,lo,hi),saturate(effect.x)),1);
}
