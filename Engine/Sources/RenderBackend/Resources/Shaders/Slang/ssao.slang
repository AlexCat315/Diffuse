#include "screen_space_common.slang"
[shader("fragment")]
float4 postFragment(PostVertex input) : SV_Target0 {
    float depth = depthAt(input.uv);
    float3 scene = sceneColor(texUV(input.uv));
    if (depth >= 0.9999) return float4(scene,1);
    float3 viewPos = viewPosition(input.uv,depth);
    float3 normal = reconstructNormal(input.uv,viewPos);
    float3 samples[8] = {float3(0.188,-0.126,0.207),float3(-0.241,0.091,0.356),
        float3(0.096,0.277,0.441),float3(-0.322,-0.251,0.523),float3(0.509,0.114,0.602),
        float3(-0.085,0.523,0.644),float3(0.387,-0.482,0.713),float3(-0.613,0.204,0.782)};
    float occlusion = 0;
    for (uint i=0; i<8; ++i) {
        float3 dir = normalize(samples[i]);
        float3 hemisphere = dot(dir,normal) >= 0 ? dir : -dir;
        float3 samplePos = viewPos+hemisphere*effect.resolution.z;
        float4 projected = mul(effect.projection,float4(samplePos,1));
        float2 uv = projected.xy/max(projected.w,0.00001)*0.5+0.5;
        if (any(uv < float2(0,0)) || any(uv > float2(1,1))) continue;
        float3 sampleView = viewPosition(uv,depthAt(uv));
        float rangeCheck = smoothstep(0,1,effect.resolution.z/(abs(viewPos.z-sampleView.z)+0.001));
        if (sampleView.z >= samplePos.z+effect.tuning.x) occlusion += rangeCheck;
    }
    float ao = pow(saturate(1-occlusion/8),max(effect.tuning.z,0.001));
    return float4(scene*lerp(1,ao,saturate(effect.tuning.y)),1);
}
