struct SkyboxUniforms {
    column_major float4x4 invViewProj;
    float4 skyTint; float4 horizonTint; float4 groundTint;
};
[[vk::binding(0,0)]] ConstantBuffer<SkyboxUniforms> sky : register(b0, space0);
struct SkyVertex { float4 position : SV_Position; float3 direction : TEXCOORD0; };
[shader("vertex")]
SkyVertex skyVertex(uint id : SV_VertexID) {
    float2 positions[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    float2 pos = positions[id];
    float4 far = mul(sky.invViewProj,float4(pos,1,1));
    float4 near = mul(sky.invViewProj,float4(pos,0,1));
    SkyVertex output;
    output.position = float4(pos,1,1);
    output.direction = normalize(far.xyz/far.w-near.xyz/near.w);
    return output;
}
[shader("fragment")]
float4 skyFragment(SkyVertex input) : SV_Target0 {
    if (sky.skyTint.w > 0.5) return float4(sky.groundTint.rgb,1);
    float3 dir = normalize(input.direction);
    float3 upper = lerp(sky.horizonTint.rgb,sky.skyTint.rgb,smoothstep(0.15,0.95,dir.y));
    float3 lower = lerp(sky.groundTint.rgb,sky.horizonTint.rgb,smoothstep(-0.95,0.15,dir.y));
    float3 color = lerp(lower,upper,smoothstep(-0.15,0.45,dir.y));
    float sun = max(dot(dir,normalize(float3(0.35,0.75,0.25))),0);
    return float4(color+float3(1.8,1.5,1.1)*pow(sun,96)+float3(0.7,0.5,0.28)*pow(sun,8)*0.18,1);
}
