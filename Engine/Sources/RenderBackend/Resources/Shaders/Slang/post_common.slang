[[vk::binding(0,0)]] SamplerState postSampler : register(s0, space0);
[[vk::binding(1,0)]] Texture2D<float4> sceneTexture : register(t1, space0);
[[vk::binding(2,0)]] Texture2D<float4> secondaryTexture : register(t2, space0);
[[vk::binding(4,0)]] ConstantBuffer<float4> frame : register(b4, space0);
struct PostVertex { float4 position : SV_Position; float2 uv : TEXCOORD0; };
[shader("vertex")]
PostVertex postVertex(uint id : SV_VertexID) {
    float2 positions[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    float2 uvs[3] = {float2(0,1),float2(2,1),float2(0,-1)};
    PostVertex output; output.position = float4(positions[id],0,1); output.uv = uvs[id]; return output;
}
float2 texUV(float2 uv) { return min(uv*frame.xy,frame.zw); }
float3 sceneColor(float2 uv) { return sceneTexture.SampleLevel(postSampler,clamp(uv,float2(0,0),frame.zw),0).rgb; }
float depthAt(float2 uv) { return secondaryTexture.SampleLevel(postSampler,texUV(uv),0).x; }
