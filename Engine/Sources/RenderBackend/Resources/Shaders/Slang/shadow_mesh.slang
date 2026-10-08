#define SHADOW_RENDER
#include "mesh_common.slang"
[shader("fragment")]
float4 shadowFragment(VertexOutput input, bool front : SV_IsFrontFace) : SV_Target0 {
    coverage(input,front);
    return float4(input.depth,input.depth,input.depth,1);
}
