struct Vertex {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : TEXCOORD1;
    nointerpolation float srgb : TEXCOORD2;
};

// Compile stages separately so offline reflection exposes only each stage's ABI.
#if UI_VERTEX_SHADER
struct Uniforms { float2 viewport; float srgb; float padding; };
[[vk::push_constant]] ConstantBuffer<Uniforms> uniforms : register(b0, space0);
struct Input { float2 position : TEXCOORD0; float2 uv : TEXCOORD1; float4 color : TEXCOORD2; };
[shader("vertex")]
Vertex uiVertex(Input input) {
    Vertex output;
    output.position = float4(input.position.x / uniforms.viewport.x * 2 - 1,
                            1 - input.position.y / uniforms.viewport.y * 2, 0, 1);
    output.uv = input.uv; output.color = input.color; output.srgb = uniforms.srgb; return output;
}
#else
[[vk::binding(1, 0)]] Texture2D<float4> atlas : register(t1, space0);
[[vk::binding(2, 0)]] SamplerState atlasSampler : register(s2, space0);
float3 srgbToLinear(float3 color) {
    float3 lower = color / 12.92;
    float3 higher = pow((color + 0.055) / 1.055, 2.4);
    return select(color <= 0.04045, lower, higher);
}
[shader("fragment")]
float4 uiFragment(Vertex input) : SV_Target {
    bool srgb = input.srgb > 0.5;
    float3 rgb = srgb ? srgbToLinear(input.color.rgb) : input.color.rgb;
    if (input.uv.x < 0) return float4(rgb, input.color.a);
    if (input.uv.x >= 20) {
        float4 sampled = atlas.SampleLevel(atlasSampler, float2(input.uv.x - 20, input.uv.y), 0);
        return float4(rgb, input.color.a * sampled.a);
    }
    if (input.uv.x >= 10) {
        float4 sampled = atlas.SampleLevel(atlasSampler, float2(input.uv.x - 10, input.uv.y), 0);
        float3 textureRGB = srgb ? srgbToLinear(sampled.rgb) : sampled.rgb;
        return float4(rgb * textureRGB, input.color.a * sampled.a);
    }
    float alpha = atlas.SampleLevel(atlasSampler, input.uv, 0).r;
    float coverage = srgb ? 1 - srgbToLinear(float3(1 - alpha)).x : pow(alpha, 0.75);
    return float4(rgb, input.color.a * coverage);
}
#endif
