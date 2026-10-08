[[vk::binding(0, 0)]] StructuredBuffer<uint> inputs;
[[vk::binding(1, 0)]] RWStructuredBuffer<uint> outputs;
[numthreads(4, 1, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) { outputs[id.x] = inputs[id.x] + 11; }
