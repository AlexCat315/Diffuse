#include "screen_space_common.slang"
[shader("fragment")]
float4 postFragment(PostVertex input) : SV_Target0 {
    float depth = depthAt(input.uv);
    float3 scene = sceneColor(texUV(input.uv));
    if (depth >= 0.9999) return float4(scene,1);
    float3 viewPos = viewPosition(input.uv,depth);
    float3 normal = reconstructNormal(input.uv,viewPos);
    float3 viewDir = effect.projection[3][3] > 0.5 ? float3(0,0,1) : normalize(-viewPos);
    float3 reflectDir = reflect(-viewDir,normal);
    if (reflectDir.z > 0) return float4(scene,1);
    int steps = int(max(effect.tuning.y,8));
    float stepSize = effect.tuning.x/max(effect.tuning.y,1);
    float2 hitUV = input.uv; bool hit = false;
    for (int i=1; i<=steps; ++i) {
        float3 samplePos = viewPos+reflectDir*stepSize*float(i);
        float4 clip = mul(effect.projection,float4(samplePos,1));
        float2 uv = clip.xy/max(clip.w,0.00001)*0.5+0.5;
        if (any(uv < float2(0,0)) || any(uv > float2(1,1))) break;
        float3 surface = viewPosition(uv,depthAt(uv));
        if (surface.z >= samplePos.z && surface.z-samplePos.z < effect.tuning.z) { hitUV=uv; hit=true; break; }
    }
    if (!hit) return float4(scene,1);
    float3 reflection = sceneColor(texUV(hitUV));
    float edge = effect.tuning.w;
    float fade = smoothstep(0,edge,hitUV.x)*smoothstep(0,edge,1-hitUV.x)
               * smoothstep(0,edge,hitUV.y)*smoothstep(0,edge,1-hitUV.y);
    return float4(lerp(scene,scene+reflection*0.5,max(effect.resolution.z,0)*fade),1);
}
