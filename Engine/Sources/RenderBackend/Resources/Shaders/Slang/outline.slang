#include "mesh_common.slang"
#include "pbr_lighting.slang"
#include "stylized_style.slang"
[shader("vertex")]
VertexOutput outlineVertex(VertexInput input, uint id : SV_InstanceID) {
    VertexOutput output = meshVertex(input,id);
    float4x4 skin = skinMatrix(input.joints,input.weights);
    float3 local = mul(skin,float4(input.position,1)).xyz;
    float3 normal = mul(skin,float4(input.normal,0)).xyz;
    output.position = mul(instances[id].mvp,float4(local+safeNormalize(normal)*style.params.w,1));
    return output;
}
[shader("fragment")]
float4 outlineFragment(VertexOutput input) : SV_Target0 {
    float alpha = baseTexture.SampleGrad(meshSampler,input.uv,ddx(input.uv),ddy(input.uv)).a*draw.colorTint.a;
    if (draw.material.x > 0.5 && alpha < draw.material.y) discard;
    return float4(0.03,0.03,0.04,1);
}
