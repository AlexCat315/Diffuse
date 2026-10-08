struct Input { float2 position : TEXCOORD0; float4 color : TEXCOORD1; };
struct Vertex { float4 position : SV_Position; float4 color : COLOR0; };
[shader("vertex")]
Vertex vertexMain(Input input) {
    Vertex output; output.position = float4(input.position, 0, 1); output.color = input.color; return output;
}
[shader("fragment")]
float4 fragmentMain(Vertex input) : SV_Target { return input.color; }
