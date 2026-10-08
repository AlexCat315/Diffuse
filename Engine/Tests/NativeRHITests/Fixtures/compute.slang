[[vk::binding(0, 0)]] RWStructuredBuffer<uint> values;
[shader("compute")]
[numthreads(8, 1, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) { values[id.x] = id.x + 7; }
