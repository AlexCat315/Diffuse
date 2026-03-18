#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_hdr_map;
layout(set = 2, binding = 1) uniform sampler2D u_bloom_map;
layout(set = 3, binding = 0, std140) uniform TonemapUniforms {
    // x: 启用手动曝光，y: 曝光倍率
    vec4 u_exposure_params;
    // x: 启用 Bloom，y: Bloom 强度
    vec4 u_bloom_params;
} tonemap_uniforms;

// ACES tonemap curve
vec3 ACESFilm(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec3 hdr_color = texture(u_hdr_map, v_uv).rgb;
    if (tonemap_uniforms.u_bloom_params.x > 0.5) {
        hdr_color += texture(u_bloom_map, v_uv).rgb * max(tonemap_uniforms.u_bloom_params.y, 0.0);
    }
    float exposure = tonemap_uniforms.u_exposure_params.x > 0.5 ? max(tonemap_uniforms.u_exposure_params.y, 0.0) : 1.0;
    hdr_color *= exposure;

    // Tonemapping
    vec3 ldr_color = ACESFilm(hdr_color);

    // Gamma correction (if the target isn't SRGB, we need to do it manually)
    // Assuming UI texture target is UNORM, we apply standard 2.2 gamma
    // ldr_color = pow(ldr_color, vec3(1.0 / 2.2));

    // If the target is .bgra8_unorm (without _srgb), we should apply gamma manually.
    // Let's do a simple pow. In many cases ImGui outputs in linear if not using SRGB framebuffers,
    // but the final swapchain is what matters. To be safe we output linear or gamma based on what we need.
    // For now, let's assume we do need gamma correction if the UI displays it as SRGB.

    out_color = vec4(ldr_color, 1.0);
}
