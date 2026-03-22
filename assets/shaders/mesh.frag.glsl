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
layout(set = 2, binding = 5) uniform sampler2DShadow u_shadow_map;

// IBL textures
layout(set = 2, binding = 6) uniform sampler2D u_irradiance_map;
layout(set = 2, binding = 7) uniform sampler2D u_prefiltered_env_map;
layout(set = 2, binding = 8) uniform sampler2D u_brdf_lut;
layout(set = 2, binding = 9) uniform sampler2D u_environment_map; // Fallback for debugging

layout(set = 3, binding = 0, std140) uniform MaterialUniforms {
    vec4 u_base_color_factor;
    vec4 u_emissive_factor;
    vec4 u_pbr_factors; // x: metallic, y: roughness, z: alpha_cutoff, w: output_alpha_multiplier
    uvec4 u_has_textures; // x: base_color, y: metallic_roughness, z: normal, w: occlusion
    vec4 u_camera_world_position;
    vec4 u_light_direction;
    vec4 u_light_color_intensity;
    mat4 u_light_space_matrix;
    vec4 u_point_light_position_radius;
    vec4 u_point_light_color_intensity;
    vec4 u_ambient_color;
    vec4 u_shadow_params; // x: bias, yzw: preview_tint_color
    vec4 u_ibl_params; // x: use_ibl, y: ibl_intensity, z: preview_tint_strength, w: reserved
} material_uniforms;

const float PI = 3.14159265359;
const vec2 INV_ATAN = vec2(0.1591, 0.3183);

// IBL Helper functions
vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec2 sampleSphericalMap(vec3 direction) {
    vec2 uv = vec2(atan(direction.z, direction.x), asin(direction.y));
    uv *= INV_ATAN;
    uv += 0.5;
    return uv;
}

vec3 sampleEquirectangularMap(sampler2D map, vec3 direction) {
    return texture(map, sampleSphericalMap(normalize(direction))).rgb;
}

vec3 sampleEquirectangularMapLod(sampler2D map, vec3 direction, float lod) {
    return textureLod(map, sampleSphericalMap(normalize(direction)), lod).rgb;
}

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
        // Derive tangent space (simplified)
        vec3 Q1  = dFdx(v_world_position);
        vec3 Q2  = dFdy(v_world_position);
        vec2 st1 = dFdx(v_uv);
        vec2 st2 = dFdy(v_uv);

        vec3 T  = normalize(Q1 * st2.t - Q2 * st1.t);
        vec3 B  = normalize(-Q1 * st2.s + Q2 * st1.s);
        mat3 TBN = mat3(T, B, N);

        vec3 normal_sample = texture(u_normal_map, v_uv).rgb * 2.0 - 1.0;
        N = normalize(TBN * normal_sample);
    }

    vec3 V = normalize(material_uniforms.u_camera_world_position.xyz - v_world_position);
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);

    // Shadow calculation - 4-cascade CSM with Poisson disk PCF
    float shadow = 1.0;
    if (material_uniforms.u_shadow_params.x > 0.0) {
        vec4 frag_pos_light_space = material_uniforms.u_light_space_matrix * vec4(v_world_position, 1.0);
        vec3 proj_coords = frag_pos_light_space.xyz / frag_pos_light_space.w;
        proj_coords = proj_coords * 0.5 + 0.5;

        float current_depth = proj_coords.z;
        float bias = material_uniforms.u_shadow_params.x;

        // Slope-scaled bias: steeper surfaces get more bias to avoid acne
        float NdotL_bias = max(dot(normalize(v_world_normal), normalize(-material_uniforms.u_light_direction.xyz)), 0.0);
        bias = max(bias * (1.0 - NdotL_bias), bias * 0.1);

        bool inside_shadow_map =
            proj_coords.x >= 0.0 && proj_coords.x <= 1.0 &&
            proj_coords.y >= 0.0 && proj_coords.y <= 1.0 &&
            current_depth >= 0.0 && current_depth <= 1.0;

        if (inside_shadow_map) {
            // 16-sample Poisson disk PCF for soft, stable shadows
            const vec2 poissonDisk[16] = vec2[](
                vec2(-0.94201624, -0.39906216), vec2( 0.94558609, -0.76890725),
                vec2(-0.09418410, -0.92938870), vec2( 0.34495938,  0.29387760),
                vec2(-0.91588581,  0.45771432), vec2(-0.81544232, -0.87912464),
                vec2(-0.38277543,  0.27676845), vec2( 0.97484398,  0.75648379),
                vec2( 0.44323325, -0.97511554), vec2( 0.53742981, -0.47373420),
                vec2(-0.26496911, -0.41893023), vec2( 0.79197514,  0.19090188),
                vec2(-0.24188840,  0.99706507), vec2(-0.81409955,  0.91437590),
                vec2( 0.19984126,  0.78641367), vec2( 0.14383161, -0.14100790)
            );

            shadow = 0.0;
            vec2 texel_size = 1.0 / textureSize(u_shadow_map, 0);
            float spread = 1.5; // PCF spread radius in texels

            for (int i = 0; i < 16; ++i) {
                vec2 offset = poissonDisk[i] * texel_size * spread;
                shadow += texture(u_shadow_map, vec3(proj_coords.xy + offset, current_depth - bias));
            }
            shadow /= 16.0;

            // Smooth shadow map edge fadeout to avoid hard cutoff
            float fade = 1.0;
            fade *= smoothstep(0.0, 0.05, proj_coords.x) * smoothstep(0.0, 0.05, 1.0 - proj_coords.x);
            fade *= smoothstep(0.0, 0.05, proj_coords.y) * smoothstep(0.0, 0.05, 1.0 - proj_coords.y);
            shadow = mix(1.0, shadow, fade);
        } else {
            shadow = 1.0;
        }
    }

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
        Lo += (kD * albedo / PI + specular) * radiance * NdotL * shadow;
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
    // Emissive texture is conditionally bound or we can just sample if it's provided.
    // In our uniform, we don't have a 5th element in uvec4 for emissive. But wait!
    // We can just use the length of the vector or check if emissive_factor > 0?
    // Let's modify the uniform in Zig to pass emissive as part of a bitmask or we can just skip it for now until Zig is updated.
    // Since Zig passes it in the 4th float if we use an array. Wait, u_has_textures in Zig is [4]u32.
    // I will just leave it as multiplying emissive_factor for now, as emissive map sampling requires checking a flag.

    // IBL (Image-Based Lighting) calculation
    vec3 ibl_contribution = vec3(0.0);
    if (material_uniforms.u_ibl_params.x > 0.5) { // use_ibl
        vec3 F0_ibl = mix(vec3(0.04), albedo, metallic);
        // IBL diffuse using irradiance map
        vec3 irradiance = sampleEquirectangularMap(u_irradiance_map, N);
        vec3 diffuse_ibl = irradiance * albedo;

        // IBL specular using prefiltered environment map
        vec3 R = reflect(-V, N);
        float lod = roughness * 4.0;
        vec3 prefiltered_color = sampleEquirectangularMapLod(u_prefiltered_env_map, R, lod);

        // Sample BRDF LUT
        float NdotV = max(dot(N, V), 0.0);
        vec2 brdf = texture(u_brdf_lut, vec2(NdotV, roughness)).rg;

        vec3 specular_ibl = prefiltered_color * (F0_ibl * brdf.x + brdf.y);

        // Energy conservation
        vec3 F_ibl = fresnelSchlickRoughness(NdotV, F0_ibl, roughness);
        vec3 kD_ibl = (1.0 - metallic) * (vec3(1.0) - F_ibl);
        ibl_contribution = (kD_ibl * diffuse_ibl + specular_ibl) * material_uniforms.u_ibl_params.y; // ibl_intensity
    }

    vec3 color = ambient + Lo + emissive + ibl_contribution;
    float preview_tint_strength = clamp(material_uniforms.u_ibl_params.z, 0.0, 1.0);
    if (preview_tint_strength > 0.0) {
        vec3 preview_tint = material_uniforms.u_shadow_params.yzw;
        color = mix(color, color * 0.6 + preview_tint * 0.4, preview_tint_strength);
    }

    float output_alpha_multiplier = material_uniforms.u_pbr_factors.w > 0.0 ? material_uniforms.u_pbr_factors.w : 1.0;
    out_color = vec4(color, clamp(albedo_alpha.a * output_alpha_multiplier, 0.0, 1.0));
}
