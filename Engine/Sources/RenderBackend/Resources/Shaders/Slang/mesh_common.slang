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

struct SkinParameters { uint4 counts; };
struct SkinMatrix { column_major float4x4 matrix; };
[[vk::binding(11,0)]] ConstantBuffer<SkinParameters> skinParameters : register(b11, space0);
[[vk::binding(12,0)]] StructuredBuffer<SkinMatrix> jointPalette : register(t12, space0);
float4x4 jointMatrix(uint index) {
    return index < skinParameters.counts.x ? jointPalette[index].matrix : float4x4(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1);
}
float4x4 skinMatrix(float4 joints, float4 weights) {
    if (dot(weights,float4(1,1,1,1)) <= 0.0001 || skinParameters.counts.x == 0)
        return float4x4(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1);
    uint4 j = uint4(joints);
    return jointMatrix(j.x)*weights.x + jointMatrix(j.y)*weights.y
         + jointMatrix(j.z)*weights.z + jointMatrix(j.w)*weights.w;
}

struct VertexInput {
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float3 color : TEXCOORD2;
    float2 uv : TEXCOORD3;
    float4 tangent : TEXCOORD4;
    float4 joints : TEXCOORD5;
    float4 weights : TEXCOORD6;
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
    float4x4 skin = skinMatrix(input.joints,input.weights);
    float4 localPosition = mul(skin,float4(input.position,1));
    float4 localNormal = mul(skin,float4(input.normal,0));
    float4 localTangent = mul(skin,float4(input.tangent.xyz,0));
#ifdef SHADOW_RENDER
    output.position = mul(shadowView.lightViewProjection, mul(instance.model, localPosition));
#else
    output.position = mul(instance.mvp, localPosition);
#endif
    output.worldPosition = mul(instance.model, localPosition).xyz;
    output.depth = saturate(output.position.z / max(output.position.w,0.00001));
    output.color = input.color * instance.colorTint.rgb;
    output.uv = input.uv;
    output.normal = safeNormalize(mul(instance.model, localNormal).xyz);
    output.tangent = safeNormalize(mul(instance.model, localTangent).xyz);
    output.bitangent = cross(output.normal, output.tangent) * input.tangent.w;
    return output;
}
void coverageAlpha(float alpha, bool front) {
    if (!front && draw.material.z < 0.5) discard;
    if (draw.material.x > 0.5 && draw.material.x < 1.5 && alpha < draw.material.y) discard;
}
void coverage(VertexOutput input, bool front) {
    // Derivatives must be evaluated while the entire quad is still active.
    float alpha = baseTexture.SampleGrad(meshSampler,input.uv,ddx(input.uv),ddy(input.uv)).a*draw.colorTint.a;
    coverageAlpha(alpha,front);
}
