[[vk::binding(0,0)]] Texture2D<float4> image : register(t0);
[[vk::binding(1,0)]] SamplerState filter : register(s1);
[[vk::binding(2,0)]] RWStructuredBuffer<float4> outputs : register(u2);
[numthreads(1,1,1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    float lod = id.x == 4 ? 1.5 : float(id.x);
    outputs[id.x] = image.SampleLevel(filter,float2(0.5),lod);
}
