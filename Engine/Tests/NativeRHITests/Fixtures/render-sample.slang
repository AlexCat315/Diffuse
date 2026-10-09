[[vk::binding(0, 0)]] Texture2D<float4> image : register(t0);
[[vk::binding(1, 0)]] SamplerState filter : register(s1);
struct Vertex { float4 position : SV_Position; };
[shader("vertex")]
Vertex vertexMain(uint id : SV_VertexID) {
    float2 positions[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    Vertex output; output.position = float4(positions[id], 0, 1); return output;
}
[shader("fragment")]
float4 fragmentMain() : SV_Target { return image.SampleLevel(filter, float2(0.5), 0); }
