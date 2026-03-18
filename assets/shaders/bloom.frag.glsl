#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_hdr_map;
layout(set = 3, binding = 0, std140) uniform BloomUniforms {
    // x: 亮部阈值
    vec4 u_threshold_params;
} bloom_uniforms;

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec3 brightSample(vec2 uv, float threshold) {
    vec3 color = texture(u_hdr_map, uv).rgb;
    float brightness = luminance(color);
    if (brightness <= threshold) {
        return vec3(0.0);
    }

    float bloom_factor = (brightness - threshold) / max(brightness, 0.0001);
    return color * bloom_factor;
}

void main() {
    float threshold = max(bloom_uniforms.u_threshold_params.x, 0.0);
    vec2 texel = 1.0 / vec2(textureSize(u_hdr_map, 0));

    // 先做一个单 pass 的阈值提取 + 邻域模糊，作为 Bloom MVP。
    vec3 sum = vec3(0.0);
    float weight_sum = 0.0;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            float distance_sq = float(x * x + y * y);
            float weight = exp(-distance_sq / 4.0);
            sum += brightSample(v_uv + vec2(x, y) * texel, threshold) * weight;
            weight_sum += weight;
        }
    }

    vec3 bloom_color = weight_sum > 0.0 ? sum / weight_sum : vec3(0.0);
    out_color = vec4(bloom_color, 1.0);
}
