#include "particle_common.slang"
struct ParticleUniforms {
    column_major float4x4 viewProj;
    float4 cameraRight;
    float4 cameraUp;
    float4 cameraForward;
};
[[vk::binding(0,0)]] ConstantBuffer<ParticleUniforms> u : register(b0,space0);
[[vk::binding(1,0)]] StructuredBuffer<ParticleInstance> particles : register(t1,space0);
[[vk::binding(2,0)]] SamplerState particleSampler : register(s2,space0);
[[vk::binding(3,0)]] Texture2D<float4> particleTexture : register(t3,space0);
struct ParticleDrawRange { uint4 first; };
[[vk::binding(4,0)]] ConstantBuffer<ParticleDrawRange> drawRange : register(b4,space0);
struct ParticleVertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : TEXCOORD1;
    float2 localUV : TEXCOORD2;
    float shape : TEXCOORD3;
};
[shader("vertex")]
ParticleVertexOutput particleVertex(uint vertexIndex : SV_VertexID, uint instanceIndex : SV_InstanceID) {
    float2 corners[6] = {float2(-0.5,-0.5),float2(0.5,-0.5),float2(0.5,0.5),
                        float2(-0.5,-0.5),float2(0.5,0.5),float2(-0.5,0.5)};
    // Slang SV_InstanceID is draw-relative on Metal/SPIR-V/DXIL. The shared
    // buffer range matches indirect firstInstance, without requiring SM 6.8
    // StartInstanceLocation semantics on DX12.
    ParticleInstance p = particles[instanceIndex+drawRange.first.x];
    float2 corner = corners[vertexIndex], localUV = corner + 0.5;
    bool ribbon = p.rotation.y > 0.5;
    float axisLength = length(p.axisStretch.xyz);
    float3 offset;
    if (axisLength > 0.0001) {
        float3 axis = p.axisStretch.xyz / axisLength;
        float3 projected = axis - u.cameraForward.xyz * dot(axis,u.cameraForward.xyz);
        float projectedLength = length(projected);
        float3 along = projectedLength > 0.0001 ? projected / projectedLength : u.cameraUp.xyz;
        float3 side = normalize(cross(along,u.cameraForward.xyz));
        if (ribbon) {
            float width = lerp(p.ribbonParams.x,p.ribbonParams.y,localUV.y);
            offset = side * corner.x * width + along * corner.y * p.axisStretch.w * p.positionSize.w;
        } else {
            offset = (side * corner.x + along * corner.y * p.axisStretch.w) * p.positionSize.w;
        }
    } else {
        float s = sin(p.rotation.x), c = cos(p.rotation.x);
        float2 rotated = float2(corner.x*c-corner.y*s,corner.x*s+corner.y*c);
        offset = (u.cameraRight.xyz*rotated.x+u.cameraUp.xyz*rotated.y)*p.positionSize.w;
    }
    ParticleVertexOutput output;
    output.position = mul(u.viewProj,float4(p.positionSize.xyz+offset,1));
    float2 sampledLocalUV = localUV;
    if (ribbon && p.rotation.w > 0.0001) sampledLocalUV.y = frac(p.rotation.z+localUV.y*p.rotation.w);
    output.uv = p.uvRect.xy + sampledLocalUV*p.uvRect.zw;
    output.localUV = localUV;
    output.color = ribbon ? lerp(p.color,p.ribbonColor,localUV.y) : p.color;
    output.shape = p.rotation.y;
    return output;
}
[shader("fragment")]
float4 particleFragment(ParticleVertexOutput input) : SV_Target0 {
    float distance = length(input.localUV-0.5)*2;
    float falloff = input.shape > 0.5 ? 1 : smoothstep(1.0,0.0,distance);
    float4 texel = particleTexture.Sample(particleSampler,input.uv);
    return float4(input.color.rgb*texel.rgb,input.color.a*texel.a*falloff);
}
