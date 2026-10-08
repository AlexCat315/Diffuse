struct Parameters { uint value; };
[[vk::push_constant]] ConstantBuffer<Parameters> parameters : register(b1);
[[vk::binding(0, 0)]] RWStructuredBuffer<uint> outputs : register(u0);
[numthreads(1, 1, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) { outputs[id.x] = parameters.value; }
