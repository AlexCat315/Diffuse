#include "post_common.slang"
struct StylizedStyle { float4 toonThresholds; float4 toonLevels; float4 inkWashColor; float4 params; };
[[vk::binding(3,0)]] ConstantBuffer<StylizedStyle> style : register(b3, space0);
float inkLuma(float3 color) { return dot(color,float3(0.2126,0.7152,0.0722)); }
float paperHash(float2 uv) {
    float2 p = float2(dot(uv,float2(127.1,311.7)),dot(uv,float2(269.5,183.3)));
    return frac(sin(p.x+p.y)*43758.5453);
}
[shader("fragment")]
float4 postFragment(PostVertex input) : SV_Target0 {
    uint width, height; sceneTexture.GetDimensions(width,height);
    float2 texel = 1/float2(width,height), uv = input.uv*frame.xy;
    float3 center = sceneColor(uv), north = sceneColor(uv+float2(0,-texel.y)), east = sceneColor(uv+float2(texel.x,0));
    float contrast = abs(inkLuma(center)-inkLuma(north))+abs(inkLuma(center)-inkLuma(east));
    float edge = clamp(contrast*1.8,0,0.22);
    float paper = (paperHash(input.uv*float2(320,180))-0.5)*style.params.x*1.8;
    float3 wash = lerp(center,center*style.inkWashColor.rgb,0.08);
    return float4(max(wash+paper-edge,float3(0)),1);
}
