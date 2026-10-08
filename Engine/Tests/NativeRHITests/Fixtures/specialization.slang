[vk::constant_id(0)] const uint localSize = 64;
[vk::constant_id(1)] const int bias = 2;
[vk::constant_id(2)] const float scale = 1;
[vk::constant_id(3)] const bool enabled = true;
[[vk::binding(0,0)]] RWStructuredBuffer<float> output : register(u0,space0);
[shader("compute")]
[numthreads(localSize,1,1)]
void specializedCompute(uint3 id : SV_DispatchThreadID) {
    output[id.x] = enabled ? (float(id.x)+float(bias))*scale+float(localSize)*0.01 : -1;
}
