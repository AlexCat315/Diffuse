// IBL (Image-Based Lighting) functions for PBR
// Based on Epic Games' Unreal Engine 4 implementation and Google Filament

// GGX Distribution function
float D_GGX(float NdotH, float roughness) {
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denom = (NdotH * NdotH) * (alpha2 - 1.0) + 1.0;
    return alpha2 / (PI * denom * denom);
}

// Fresnel-Schlick approximation
vec3 F_Schlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

vec3 F_SchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(1.0 - cosTheta, 5.0);
}

// Geometry function (Smith's method)
float G_Smith(float NdotV, float NdotL, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    float ggx1 = NdotV / (NdotV * (1.0 - k) + k);
    float ggx2 = NdotL / (NdotL * (1.0 - k) + k);
    return ggx1 * ggx2;
}

// Importance-sampled GGX
vec2 IntegrateBRDF(float NdotV, float roughness) {
    vec2 result = vec2(0.0);
    
    // Sample count for Monte Carlo integration
    const int SAMPLE_COUNT = 64;
    
    for (int i = 0; i < SAMPLE_COUNT; ++i) {
        // Hammersley sequence for low-discrepancy sampling
        vec2 Xi = Hammersley(i, SAMPLE_COUNT);
        
        // Importance sample GGX
        vec3 H = ImportanceSampleGGX(Xi, roughness, vec3(0.0, 0.0, 1.0));
        vec3 L = reflect(-vec3(0.0, 0.0, 1.0), H);
        
        float NdotL = max(L.z, 0.0);
        float NdotH = max(H.z, 0.0);
        float VdotH = max(dot(vec3(0.0, 0.0, 1.0), H), 0.0);
        
        if (NdotL > 0.0) {
            // GGX Geometry term
            float G = G_Smith(NdotV, NdotL, roughness);
            float G_Vis = G * VdotH / (NdotH * NdotV);
            
            // Fresnel
            float Fc = pow(1.0 - VdotH, 5.0);
            
            result.x += (1.0 - Fc) * G_Vis;
            result.y += Fc * G_Vis;
        }
    }
    
    return result / float(SAMPLE_COUNT);
}

// Hammersley low-discrepancy sequence
vec2 Hammersley(int i, int N) {
    return vec2(float(i) / float(N), RadicalInverse_VanDerCorpus(i));
}

// Van Der Corpus radical inverse
float RadicalInverse_VanDerCorpus(int bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

// Importance sample GGX NDF
vec3 ImportanceSampleGGX(vec2 Xi, float roughness, vec3 N) {
    float alpha = roughness * roughness;
    
    float phi = 2.0 * PI * Xi.x;
    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    
    // Spherical to cartesian
    vec3 H;
    H.x = cos(phi) * sinTheta;
    H.y = sin(phi) * sinTheta;
    H.z = cosTheta;
    
    // Tangent space to world space
    vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, N));
    vec3 bitangent = cross(N, tangent);
    
    return tangent * H.x + bitangent * H.y + N * H.z;
}

// IBL Diffuse (Irradiance) using Spherical Harmonics
vec3 IBL_Diffuse_SH(vec3 N, vec3 albedo) {
    // Simple SH evaluation for diffuse
    // In a real implementation, use precomputed SH coefficients from environment map
    vec3 irradiance = vec3(0.5); // Placeholder - should come from SH evaluation
    return albedo * irradiance;
}

// IBL Specular using Prefiltered Environment Map
vec3 IBL_Specular_Prefiltered(vec3 N, vec3 V, float roughness, vec3 F0) {
    vec3 R = reflect(-V, N);
    vec3 prefilteredColor = textureLod(u_prefilteredEnvMap, R, roughness * 5.0).rgb;
    
    // Sample BRDF LUT
    vec2 brdf = texture(u_brdfLUT, vec2(dot(N, V), roughness)).rg;
    
    return prefilteredColor * (F0 * brdf.x + brdf.y);
}

// Main IBL integration function
vec3 IBL_PBR(vec3 N, vec3 V, vec3 albedo, float metallic, float roughness) {
    // Compute reflectance at normal incidence (F0)
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    
    // Diffuse IBL
    vec3 diffuse = IBL_Diffuse_SH(N, albedo);
    
    // Specular IBL
    vec3 specular = IBL_Specular_Prefiltered(N, V, roughness, F0);
    
    // Energy conservation
    vec3 kD = (1.0 - metallic) * (1.0 - F_SchlickRoughness(max(dot(N, V), 0.0), F0, roughness));
    
    return kD * diffuse + specular;
}

// Simple environment map sampling (for fallback or testing)
vec3 sampleEnvironmentMap(vec3 direction) {
    // Convert direction to equirectangular UV
    vec2 uv = vec2(atan(direction.z, direction.x) / (2.0 * PI) + 0.5, 
                   asin(direction.y) / PI + 0.5);
    return texture(u_environmentMap, uv).rgb;
}

// BRDF LUT generation (for offline computation)
vec2 integrateBRDF(float NdotV, float roughness) {
    vec3 V = vec3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);
    
    float A = 0.0;
    float B = 0.0;
    
    const int SAMPLE_COUNT = 1024;
    for (int i = 0; i < SAMPLE_COUNT; ++i) {
        vec2 Xi = Hammersley(i, SAMPLE_COUNT);
        vec3 H = ImportanceSampleGGX(Xi, roughness, vec3(0.0, 0.0, 1.0));
        vec3 L = reflect(-V, H);
        
        float NdotL = max(L.z, 0.0);
        float NdotH = max(H.z, 0.0);
        float VdotH = max(dot(V, H), 0.0);
        
        if (NdotL > 0.0) {
            float G = G_Smith(NdotV, NdotL, roughness);
            float G_Vis = G * VdotH / (NdotH * NdotV);
            float Fc = pow(1.0 - VdotH, 5.0);
            
            A += (1.0 - Fc) * G_Vis;
            B += Fc * G_Vis;
        }
    }
    
    return vec2(A, B) / float(SAMPLE_COUNT);
}
