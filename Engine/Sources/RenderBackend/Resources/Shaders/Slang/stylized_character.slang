#include "mesh_common.slang"
#include "pbr_lighting.slang"
#include "stylized_style.slang"
float toonRamp(float v) {
    if (v < style.toonThresholds.x) return style.toonLevels.x;
    if (v < style.toonThresholds.y) return style.toonLevels.y;
    return style.toonLevels.z;
}
float paperGrain(float2 uv) {
    float2 p = frac(float2(dot(uv,float2(127.1,311.7)),dot(uv,float2(269.5,183.3))));
    return frac(sin(p.x+p.y)*43758.5453);
}
float sceneLambert(float3 normal, float3 world) {
    float lighting = sceneLights.ambientColorIntensity.a;
    uint count = min(uint(sceneLights.exposureLightCount.y),8);
    for (uint i=0; i<count; ++i) {
        SceneLight light = sceneLights.lights[i];
        float3 L = float3(0,1,0); float attenuation = 1;
        if (light.positionType.w < 0.5) L = safeNormalize(-light.directionRange.xyz);
        else {
            float3 offset = light.positionType.xyz-world;
            float distance = length(offset); L = safeNormalize(offset);
            float normalizedDistance = saturate(distance/max(light.directionRange.w,0.001));
            attenuation = pow(1-normalizedDistance,2);
            if (light.positionType.w >= 1.5) {
                float cone = dot(safeNormalize(light.directionRange.xyz),safeNormalize(world-light.positionType.xyz));
                attenuation *= smoothstep(cos(light.spotAngles.y),cos(light.spotAngles.x),cone);
            }
        }
        lighting += max(dot(normal,L),0)*light.colorIntensity.a*attenuation;
    }
    return clamp(lighting,0,1.5);
}
[shader("fragment")]
float4 stylizedFragment(VertexOutput input, bool front : SV_IsFrontFace) : SV_Target0 {
    float2 dx = ddx(input.uv), dy = ddy(input.uv);
    float4 texel = baseTexture.SampleGrad(meshSampler,input.uv,dx,dy);
    float3 tangentNormal = normalTexture.SampleGrad(meshSampler,input.uv,dx,dy).rgb*2-1;
    coverageAlpha(texel.a*draw.colorTint.a,front);
    float sign = front ? 1 : -1;
    float3 N = safeNormalize(input.normal)*sign, T = safeNormalize(input.tangent)*sign, B = safeNormalize(input.bitangent)*sign;
    float3 normal = safeNormalize(T*tangentNormal.x+B*tangentNormal.y+N*tangentNormal.z);
    float ramp = toonRamp(sceneLambert(normal,input.worldPosition));
    float rim = smoothstep(0.38,0.95,1-max(normal.z,0));
    float bias = frac(input.materialIndex*0.173)*style.params.z;
    float grain = (paperGrain(input.uv*83)-0.5)*style.params.x;
    float3 base = lerp(style.inkWashColor.rgb,input.color*texel.rgb,0.78);
    float3 shaded = base*(0.28+ramp*0.92+rim*style.params.y+bias+grain);
    return float4(shaded,draw.material.x > 1.5 ? texel.a*draw.colorTint.a : 1);
}
