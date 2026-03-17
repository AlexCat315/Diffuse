#version 450

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec3 v_world_normal;
layout(location = 3) in vec3 v_world_position;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_base_color_map;
layout(set = 2, binding = 1) uniform sampler2D u_metallic_roughness_map;
layout(set = 2, binding = 2) uniform sampler2D u_normal_map;
layout(set = 2, binding = 3) uniform sampler2D u_occlusion_map;
layout(set = 2, binding = 4) uniform sampler2D u_emissive_map;

layout(set = 3, binding = 0, std140) uniform MaterialUniforms {
    vec4 u_base_color_factor;
    vec4 u_emissive_factor;
    vec4 u_pbr_factors; // x: metallic, y: roughness, z: alpha_cutoff
    uvec4 u_has_textures; // x: base_color, y: metallic_roughness, z: normal, w: occlusion
    vec4 u_camera_world_position;
    vec4 u_light_direction;
    vec4 u_light_color_intensity;
    vec4 u_point_light_position_radius;
    vec4 u_point_light_color_intensity;
    vec4 u_ambient_color;
} material_uniforms;

const float PI = 3.14159265359;

// Cook-Torrance BRDF functions
float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float num = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return num / max(denom, 0.0000001);
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    return num / denom;
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 ACESFilm(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec4 base_sample = material_uniforms.u_has_textures.x > 0 ? texture(u_base_color_map, v_uv) : vec4(1.0);
    vec4 albedo_alpha = base_sample * v_color * material_uniforms.u_base_color_factor;
    
    // Alpha test
    if (albedo_alpha.a < material_uniforms.u_pbr_factors.z) {
        discard;
    }

    vec3 albedo = albedo_alpha.rgb;
    
    float metallic = material_uniforms.u_pbr_factors.x;
    float roughness = material_uniforms.u_pbr_factors.y;
    if (material_uniforms.u_has_textures.y > 0) {
        vec4 mr_sample = texture(u_metallic_roughness_map, v_uv);
        metallic *= mr_sample.b;
        roughness *= mr_sample.g;
    }

    vec3 N = normalize(v_world_normal);
    if (material_uniforms.u_has_textures.z > 0) {
        // Simple normal mapping (assuming tangent space isn't provided, we derive it)
        // This is a placeholder for proper tangent space normal mapping
        vec3 normal_sample = texture(u_normal_map, v_uv).rgb * 2.0 - 1.0;
        // ... Proper TBN would go here
    }

    vec3 V = normalize(material_uniforms.u_camera_world_position.xyz - v_world_position);
    vec3 F0 = vec3(0.04); 
    F0 = mix(F0, albedo, metallic);

    // Reflectance equation
    vec3 Lo = vec3(0.0);

    // Directional Light
    {
        vec3 L = normalize(-material_uniforms.u_light_direction.xyz);
        vec3 H = normalize(V + L);
        float distance = 1.0;
        float attenuation = 1.0;
        vec3 radiance = material_uniforms.u_light_color_intensity.rgb * material_uniforms.u_light_color_intensity.w;

        // Cook-Torrance BRDF
        float NDF = DistributionGGX(N, H, roughness);
        float G = GeometrySmith(N, V, L, roughness);
        vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

        vec3 kS = F;
        vec3 kD = vec3(1.0) - kS;
        kD *= 1.0 - metallic;

        vec3 numerator = NDF * G * F;
        float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
        vec3 specular = numerator / denominator;

        float NdotL = max(dot(N, L), 0.0);
        Lo += (kD * albedo / PI + specular) * radiance * NdotL;
    }

    // Point Light
    {
        vec3 L_vec = material_uniforms.u_point_light_position_radius.xyz - v_world_position;
        float distance = length(L_vec);
        vec3 L = normalize(L_vec);
        vec3 H = normalize(V + L);
        
        float attenuation = clamp(1.0 - distance / max(material_uniforms.u_point_light_position_radius.w, 0.001), 0.0, 1.0);
        attenuation *= attenuation;
        vec3 radiance = material_uniforms.u_point_light_color_intensity.rgb * material_uniforms.u_point_light_color_intensity.w * attenuation;

        float NDF = DistributionGGX(N, H, roughness);
        float G = GeometrySmith(N, V, L, roughness);
        vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

        vec3 kS = F;
        vec3 kD = vec3(1.0) - kS;
        kD *= 1.0 - metallic;

        vec3 numerator = NDF * G * F;
        float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
        vec3 specular = numerator / denominator;

        float NdotL = max(dot(N, L), 0.0);
        Lo += (kD * albedo / PI + specular) * radiance * NdotL;
    }

    vec3 ambient = material_uniforms.u_ambient_color.rgb * albedo;
    if (material_uniforms.u_has_textures.w > 0) {
        ambient *= texture(u_occlusion_map, v_uv).r;
    }

    vec3 emissive = material_uniforms.u_emissive_factor.rgb * material_uniforms.u_emissive_factor.w;
    // Emissive texture is binding 4
    // We didn't add has_textures.z for emissive yet, let's assume bitmask in has_textures.x if needed
    // or just check if it's there. For now let's skip emissive texture check to be safe.

    vec3 color = ambient + Lo + emissive;
    color = ACESFilm(color);

    out_color = vec4(color, albedo_alpha.a);
}
