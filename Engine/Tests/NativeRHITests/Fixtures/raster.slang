struct Vertex { float4 position : SV_Position; };
struct Parameters { float4 color; };
[[vk::binding(0, 0)]] ConstantBuffer<Parameters> parameters;
[shader("vertex")]
Vertex vertexMain(uint id : SV_VertexID) {
    float2 positions[3] = { float2(-1,-1), float2(1,-1), float2(0,1) };
    Vertex output; output.position = float4(positions[id] * parameters.color.w, 0, 1); return output;
}
[shader("fragment")]
float4 fragmentMain() : SV_Target { return parameters.color; }
