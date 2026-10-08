#include "mesh_common.slang"
#include "pbr_lighting.slang"
#include "stylized_style.slang"
float acesInverse(float y) {
    float yy = clamp(y,0,0.9999);
    float A = yy*2.43-2.51, B = yy*0.59-0.03, C = yy*0.14;
    return max((-B-sqrt(max(B*B-4*A*C,0)))/(2*A),0);
}
float3 debugPresent(float3 display) {
    float3 c = saturate(display);
    float3 lin;
    for (int i=0; i<3; ++i) lin[i] = c[i] > 0.04045 ? pow((c[i]+0.055)/1.055,2.4) : c[i]/12.92;
    return float3(acesInverse(lin.r), acesInverse(lin.g), acesInverse(lin.b))/max(sceneLights.exposureLightCount.x,0.001);
}
[shader("fragment")]
float4 meshFragment(VertexOutput input, bool front : SV_IsFrontFace) : SV_Target0 {
    float2 dx = ddx(input.uv), dy = ddy(input.uv);
    float4 texel = baseTexture.SampleGrad(meshSampler,input.uv,dx,dy);
    float3 arm = mrTexture.SampleGrad(meshSampler,input.uv,dx,dy).rgb;
    float3 tangentNormal = normalTexture.SampleGrad(meshSampler,input.uv,dx,dy).rgb*2-1;
    coverageAlpha(texel.a*draw.colorTint.a,front);
    float ao = arm.r, roughness = clamp(arm.g,0.05,1), metallic = arm.b;
    float sign = front ? 1 : -1;
    float3 n = safeNormalize(input.normal)*sign;
    float3 t = safeNormalize(input.tangent)*sign;
    float3 b = safeNormalize(input.bitangent)*sign;
    float3 normal = safeNormalize(t*tangentNormal.x+b*tangentNormal.y+n*tangentNormal.z);
    int mode = int(sceneLights.exposureLightCount.z+0.5);
    float3 color;
    if (mode != 0) {
        float3 display = saturate(input.color*texel.rgb)*ao;
        if (mode == 2) display = texel.rgb;
        if (mode == 3) display = normal*0.5+0.5;
        if (mode == 4) display = roughness;
        if (mode == 5) display = metallic;
        color = debugPresent(display);
    } else {
    float3 albedo = pow(input.color*texel.rgb,float3(2.2));
    float3 V = shadow.cameraPosition.w > 0.5 ? -shadow.cameraForward.xyz : safeNormalize(shadow.cameraPosition.xyz-input.worldPosition);
    float3 R = reflect(-V,n);
    float NdotV = max(dot(normal,V),0.001);
    float3 F0 = lerp(float3(0.04),albedo,metallic);
    float3 diffuseAlbedo = albedo*(1-metallic);
    float3 direct = directLighting(normal,V,input.worldPosition,diffuseAlbedo,F0,roughness);
    float2 brdf = environmentBRDF(NdotV,roughness);
    float3 envSpec = iblSample(R,roughness*5)*(F0*brdf.x+brdf.y);
    float3 envDiff = iblSample(normal,5)*diffuseAlbedo;
    float3 ambient = (envSpec+envDiff)*ao*sceneLights.ambientColorIntensity.a;
    color = (direct+ambient)*sceneLights.exposureLightCount.x;
    }
    return float4(color,draw.material.x > 1.5 ? texel.a*draw.colorTint.a : 1);
}
[shader("fragment")]
void depthFragment(VertexOutput input, bool front : SV_IsFrontFace) { coverage(input,front); }
