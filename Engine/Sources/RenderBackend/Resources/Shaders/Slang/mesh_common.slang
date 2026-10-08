struct DrawUniforms {
    column_major float4x4 mvp;
    column_major float4x4 model;
    float4 colorTint;
    float4 material;
};
[[vk::binding(0,0)]] ConstantBuffer<DrawUniforms> draw : register(b0, space0);
[[vk::binding(1,0)]] StructuredBuffer<DrawUniforms> instances : register(t1, space0);
[[vk::binding(2,0)]] SamplerState meshSampler : register(s2, space0);
[[vk::binding(3,0)]] Texture2D<float4> baseTexture : register(t3, space0);

struct VertexInput {
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float3 color : TEXCOORD2;
    float2 uv : TEXCOORD3;
    float4 tangent : TEXCOORD4;
};
struct VertexOutput {
    float4 position : SV_Position;
    float3 color : TEXCOORD0;
    float2 uv : TEXCOORD1;
    float3 normal : TEXCOORD2;
    float3 tangent : TEXCOORD3;
    float3 bitangent : TEXCOORD4;
    float3 worldPosition : TEXCOORD5;
    float depth : TEXCOORD6;
};
float3 safeNormalize(float3 v) { return dot(v,v) > 0.000001 ? v * rsqrt(dot(v,v)) : float3(0,1,0); }
#ifdef SHADOW_RENDER
struct ShadowView { column_major float4x4 lightViewProjection; };
[[vk::binding(4,0)]] ConstantBuffer<ShadowView> shadowView : register(b4, space0);
#endif
[shader("vertex")]
VertexOutput meshVertex(VertexInput input, uint id : SV_InstanceID) {
    DrawUniforms instance = instances[id];
    VertexOutput output;
#ifdef SHADOW_RENDER
    output.position = mul(shadowView.lightViewProjection, mul(instance.model, float4(input.position,1)));
#else
    output.position = mul(instance.mvp, float4(input.position,1));
#endif
    output.worldPosition = mul(instance.model, float4(input.position,1)).xyz;
    output.depth = saturate(output.position.z / max(output.position.w,0.00001));
    output.color = input.color * instance.colorTint.rgb;
    output.uv = input.uv;
    output.normal = safeNormalize(mul(instance.model, float4(input.normal,0)).xyz);
    output.tangent = safeNormalize(mul(instance.model, float4(input.tangent.xyz,0)).xyz);
    output.bitangent = cross(output.normal, output.tangent) * input.tangent.w;
    return output;
}
void coverageAlpha(float alpha, bool front) {
    if (!front && draw.material.z < 0.5) discard;
    if (draw.material.x > 0.5 && alpha < draw.material.y) discard;
}
void coverage(VertexOutput input, bool front) {
    // Derivatives must be evaluated while the entire quad is still active.
    float alpha = baseTexture.SampleGrad(meshSampler,input.uv,ddx(input.uv),ddy(input.uv)).a*draw.colorTint.a;
    coverageAlpha(alpha,front);
}
