// Matches SceneLightUniforms (544 bytes) and ShadowUniforms (384 bytes).
struct SceneLight { float4 positionType; float4 directionRange; float4 colorIntensity; float4 spotAngles; };
struct SceneLights { float4 ambientColorIntensity; float4 exposureLightCount; SceneLight lights[8]; };
struct Shadows {
    column_major float4x4 matrices[4];
    float4 params[4]; float4 atlasParams; float4 splits; float4 cameraPosition; float4 cameraForward;
};
[[vk::binding(4,0)]] ConstantBuffer<SceneLights> sceneLights : register(b4, space0);
[[vk::binding(5,0)]] Texture2D<float4> normalTexture : register(t5, space0);
[[vk::binding(6,0)]] Texture2D<float4> mrTexture : register(t6, space0);
[[vk::binding(7,0)]] ConstantBuffer<Shadows> shadow : register(b7, space0);
[[vk::binding(8,0)]] SamplerState shadowSampler : register(s8, space0);
[[vk::binding(9,0)]] Texture2D<float4> shadowTexture : register(t9, space0);
[[vk::binding(10,0)]] Texture2D<float4> iblTexture : register(t10, space0);

uint cascadeIndex(float3 world, uint count) {
    if (count <= 1) return 0;
    float depth = dot(world-shadow.cameraPosition.xyz,shadow.cameraForward.xyz);
    if (depth <= shadow.splits.x) return 0;
    if (count <= 2 || depth <= shadow.splits.y) return 1;
    if (count <= 3 || depth <= shadow.splits.z) return 2;
    return 3;
}
float depthLit(float2 uv, float depth, float bias) {
    return depth-bias > shadowTexture.SampleLevel(shadowSampler,uv,0).r ? 0 : 1;
}
float shadowVisibility(float3 world, uint baseSlot, uint count) {
    uint slot = baseSlot+cascadeIndex(world,count);
    if (shadow.atlasParams.x < 0.5 || float(slot) >= shadow.atlasParams.y) return 1;
    float4 clip = mul(shadow.matrices[slot],float4(world,1));
    float3 ndc = clip.xyz / max(abs(clip.w),0.00001);
    float2 localUV = float2(ndc.x*0.5+0.5,0.5-ndc.y*0.5);
    if (any(localUV < 0) || any(localUV > 1) || ndc.z < 0 || ndc.z > 1) return 1;
    float4 params = shadow.params[slot];
    float2 uv = params.zw+localUV*shadow.atlasParams.z/max(shadow.atlasParams.w,1);
    float texel = 1/max(shadow.atlasParams.w,1);
    float lit = depthLit(uv,ndc.z,params.x);
    lit += depthLit(uv+float2(texel,0),ndc.z,params.x);
    lit += depthLit(uv+float2(-texel,0),ndc.z,params.x);
    lit += depthLit(uv+float2(0,texel),ndc.z,params.x);
    lit += depthLit(uv+float2(0,-texel),ndc.z,params.x);
    return 1-saturate(params.y)*(1-lit/5);
}
float3 iblSample(float3 direction, float lod) {
    float2 uv = float2(atan2(direction.z,direction.x)*0.15915494+0.5,acos(clamp(direction.y,-1,1))*0.31830989);
    return iblTexture.SampleLevel(meshSampler,uv,lod).rgb;
}
float2 environmentBRDF(float NdotV, float roughness) {
    float4 r = roughness*float4(-1,-0.0275,-0.572,0.022)+float4(1,0.0425,1.04,-0.04);
    float a004 = min(r.x*r.x,exp2(-9.28*NdotV))*r.x+r.y;
    return float2(-1.04,1.04)*a004+r.zw;
}
float3 directLighting(float3 N, float3 V, float3 world, float3 diffuseAlbedo, float3 F0, float roughness) {
    const float PI = 3.14159265359;
    float NdotV = max(dot(N,V),0.0001);
    float3 result = sceneLights.ambientColorIntensity.rgb*sceneLights.ambientColorIntensity.a*diffuseAlbedo;
    uint count = min(uint(sceneLights.exposureLightCount.y),8);
    for (uint i=0; i<count; ++i) {
        SceneLight light = sceneLights.lights[i];
        float3 L; float attenuation = 1;
        if (light.positionType.w < 0.5) L = safeNormalize(-light.directionRange.xyz);
        else {
            float3 offset = light.positionType.xyz-world;
            L = safeNormalize(offset);
            attenuation = pow(1-saturate(length(offset)/max(light.directionRange.w,0.001)),2);
        }
        float NdotL = max(dot(N,L),0);
        if (NdotL <= 0) continue;
        float visibility = 1;
        if (light.positionType.w < 0.5) {
            int slot = int(light.spotAngles.z)-1;
            if (slot >= 0) visibility = shadowVisibility(world,uint(slot),uint(max(light.spotAngles.w,1)));
        }
        float3 radiance = light.colorIntensity.rgb*light.colorIntensity.a*attenuation*visibility;
        float3 H = safeNormalize(V+L);
        float NdotH = max(dot(N,H),0), HdotV = max(dot(H,V),0);
        float a = roughness*roughness, a2 = a*a;
        float denom = NdotH*NdotH*(a2-1)+1;
        float D = a2/max(PI*denom*denom,0.000001);
        float k = (roughness+1)*(roughness+1)/8;
        float G = (NdotV/(NdotV*(1-k)+k))*(NdotL/(NdotL*(1-k)+k));
        float3 F = F0+(1-F0)*pow(saturate(1-HdotV),5);
        float3 specular = D*G*F/max(4*NdotV*NdotL,0.0001);
        result += ((1-F)*diffuseAlbedo/PI+specular)*radiance*NdotL;
    }
    return result;
}
