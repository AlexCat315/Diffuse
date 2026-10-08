// Shares MeshAsset's vertex inputs and MeshInstanceUniforms' 160-byte ABI.
// The first migration stage preserves WGSL's material inspection modes.
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
[[vk::binding(4,0)]] ConstantBuffer<float4> settings : register(b4, space0); // mode, exposure
[[vk::binding(5,0)]] Texture2D<float4> normalTexture : register(t5, space0);
[[vk::binding(6,0)]] Texture2D<float4> mrTexture : register(t6, space0);

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
};
float3 safeNormalize(float3 v) { return dot(v,v) > 0.000001 ? v * rsqrt(dot(v,v)) : float3(0,1,0); }
[shader("vertex")]
VertexOutput meshVertex(VertexInput input, uint id : SV_InstanceID) {
    DrawUniforms instance = instances[id];
    VertexOutput output;
    output.position = mul(instance.mvp, float4(input.position,1));
    output.color = input.color * instance.colorTint.rgb;
    output.uv = input.uv;
    output.normal = safeNormalize(mul(instance.model, float4(input.normal,0)).xyz);
    output.tangent = safeNormalize(mul(instance.model, float4(input.tangent.xyz,0)).xyz);
    output.bitangent = cross(output.normal, output.tangent) * input.tangent.w;
    return output;
}
void coverage(VertexOutput input, bool front) {
    if (!front && draw.material.z < 0.5) discard;
    float alpha = baseTexture.Sample(meshSampler, input.uv).a * draw.colorTint.a;
    if (draw.material.x > 0.5 && alpha < draw.material.y) discard;
}
float acesInverse(float y) {
    float yy = clamp(y,0,0.9999);
    float A = yy*2.43-2.51, B = yy*0.59-0.03, C = yy*0.14;
    return max((-B-sqrt(max(B*B-4*A*C,0)))/(2*A),0);
}
float3 debugPresent(float3 display) {
    float3 c = saturate(display);
    float3 lin;
    for (int i=0; i<3; ++i) lin[i] = c[i] > 0.04045 ? pow((c[i]+0.055)/1.055,2.4) : c[i]/12.92;
    return float3(acesInverse(lin.r), acesInverse(lin.g), acesInverse(lin.b))/max(settings.y,0.001);
}
[shader("fragment")]
float4 meshFragment(VertexOutput input, bool front : SV_IsFrontFace) : SV_Target0 {
    coverage(input,front);
    float4 texel = baseTexture.Sample(meshSampler,input.uv);
    float3 arm = mrTexture.Sample(meshSampler,input.uv).rgb;
    float3 display = saturate(input.color*texel.rgb)*arm.r;
    int mode = int(settings.x+0.5);
    if (mode == 2) display = texel.rgb;
    if (mode == 3) {
        float3 n = safeNormalize(input.normal)*(front ? 1 : -1);
        float3 t = safeNormalize(input.tangent)*(front ? 1 : -1);
        float3 b = safeNormalize(input.bitangent)*(front ? 1 : -1);
        float3 tangentNormal = normalTexture.Sample(meshSampler,input.uv).rgb*2-1;
        display = safeNormalize(t*tangentNormal.x+b*tangentNormal.y+n*tangentNormal.z)*0.5+0.5;
    }
    if (mode == 4) display = clamp(arm.g,0.05,1);
    if (mode == 5) display = arm.b;
    return float4(debugPresent(display),1);
}
[shader("fragment")]
void depthFragment(VertexOutput input, bool front : SV_IsFrontFace) { coverage(input,front); }
