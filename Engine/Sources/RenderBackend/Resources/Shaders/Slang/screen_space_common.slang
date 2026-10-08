#include "post_common.slang"
struct ScreenSpaceUniforms {
    column_major float4x4 projection;
    column_major float4x4 invProjection;
    float4 resolution;
    float4 tuning;
};
[[vk::binding(3,0)]] ConstantBuffer<ScreenSpaceUniforms> effect : register(b3, space0);
float3 viewPosition(float2 uv, float depth) {
    float4 view = mul(effect.invProjection,float4(uv*2-1,depth,1));
    return view.xyz/max(view.w,0.00001);
}
float3 reconstructNormal(float2 uv, float3 viewPos) {
    float2 texel = 1/effect.resolution.xy;
    float2 ux = clamp(uv+float2(texel.x,0),float2(0,0),float2(1,1));
    float2 uy = clamp(uv+float2(0,texel.y),float2(0,0),float2(1,1));
    float3 vx = viewPosition(ux,depthAt(ux));
    float3 vy = viewPosition(uy,depthAt(uy));
    return normalize(cross(vx-viewPos,vy-viewPos));
}
