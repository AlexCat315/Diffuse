#include "post_common.slang"
[[vk::binding(3,0)]] ConstantBuffer<float4> effect : register(b3, space0);
[shader("fragment")]
float4 postFragment(PostVertex input) : SV_Target0 {
    float3 bloom = 0; float total = 0;
    for (int y=-1; y<=1; ++y) for (int x=-1; x<=1; ++x) {
        float weight = (x == 0 ? 2 : 1)*(y == 0 ? 2 : 1);
        float3 color = sceneColor(input.uv*frame.xy+float2(x,y)*effect.zw*2);
        float bright = max(dot(color,float3(0.2126,0.7152,0.0722))-effect.x,0);
        bloom += color*bright*weight; total += weight;
    }
    return float4(bloom/max(total,0.0001)*max(effect.y,0),1);
}
