[[vk::binding(0,0)]] SamplerState toneSampler : register(s0, space0);
[[vk::binding(1,0)]] Texture2D<float4> hdrTexture : register(t1, space0);
[[vk::binding(2,0)]] ConstantBuffer<float4> tone : register(b2, space0);
[[vk::binding(3,0)]] ConstantBuffer<float4> frame : register(b3, space0);
struct ToneVertex { float4 position : SV_Position; float2 uv : TEXCOORD0; };
[shader("vertex")]
ToneVertex toneVertex(uint id : SV_VertexID) {
    float2 positions[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    float2 uvs[3] = {float2(0,1),float2(2,1),float2(0,-1)};
    ToneVertex output; output.position = float4(positions[id],0,1); output.uv = uvs[id]; return output;
}
[shader("fragment")]
float4 toneFragment(ToneVertex input) : SV_Target0 {
    float2 uv = min(input.uv*frame.xy,frame.zw);
    float3 hdr = hdrTexture.Sample(toneSampler,uv).rgb*max(tone.x,0.001);
    float3 ldr = saturate((hdr*(2.51*hdr+0.03))/(hdr*(2.43*hdr+0.59)+0.14));
    if (tone.w > 0.5) {
        for (int i=0; i<3; ++i) ldr[i] = ldr[i] >= 0.0031308 ? 1.055*pow(max(ldr[i],0),1/2.4)-0.055 : ldr[i]*12.92;
    }
    return float4(ldr,1);
}
