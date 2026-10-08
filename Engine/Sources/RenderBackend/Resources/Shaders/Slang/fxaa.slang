#include "post_common.slang"
[[vk::binding(3,0)]] ConstantBuffer<float4> effect : register(b3, space0);
float luma(float3 color) { return dot(color,float3(0.299,0.587,0.114)); }
[shader("fragment")]
float4 postFragment(PostVertex input) : SV_Target0 {
    float2 texel = effect.xy, uv = input.uv*frame.xy;
    float3 m = sceneColor(uv), n = sceneColor(uv+float2(0,-texel.y)), s = sceneColor(uv+float2(0,texel.y));
    float3 w = sceneColor(uv+float2(-texel.x,0)), e = sceneColor(uv+float2(texel.x,0));
    float lm=luma(m), ln=luma(n), ls=luma(s), lw=luma(w), le=luma(e);
    float lo=min(lm,min(min(ln,ls),min(lw,le))), hi=max(lm,max(max(ln,ls),max(lw,le)));
    if (hi-lo < max(0.0312,hi*0.125)) return float4(m,1);
    float2 dir = float2(-((ln+ls)-2*lm),(lw+le)-2*lm);
    float reduce = max((ln+ls+lw+le)*0.25*0.0312,0.0078125);
    dir = clamp(dir/(min(abs(dir.x),abs(dir.y))+reduce),float2(-8,-8),float2(8,8))*texel;
    float3 a = (sceneColor(uv+dir*(1.0/3-0.5))+sceneColor(uv+dir*(2.0/3-0.5)))*0.5;
    float3 b = a*0.5+(sceneColor(uv-dir*0.5)+sceneColor(uv+dir*0.5))*0.25;
    float lb = luma(b);
    return float4(lb < lo || lb > hi ? a : b,1);
}
