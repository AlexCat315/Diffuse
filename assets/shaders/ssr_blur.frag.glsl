#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_ssr_texture;
layout(set = 2, binding = 1) uniform sampler2D u_depth_texture;

layout(set = 3, binding = 0, std140) uniform SSRBlurUniforms {
    vec2 u_direction;        // (1,0) for horizontal, (0,1) for vertical
    float u_blur_strength;   // blur radius multiplier (0 = no blur)
    float u_depth_threshold; // bilateral depth threshold
};

// 9-tap Gaussian kernel (sigma ≈ 2.0)
const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);

void main() {
    vec4 center = texture(u_ssr_texture, v_uv);

    if (u_blur_strength <= 0.001) {
        out_color = center;
        return;
    }

    vec2 texel_size = 1.0 / vec2(textureSize(u_ssr_texture, 0));
    float center_depth = texture(u_depth_texture, v_uv).r;

    vec4 result = center * weights[0];
    float total_weight = weights[0];

    vec2 step_dir = u_direction * texel_size * u_blur_strength * 2.0;

    for (int i = 1; i < 5; ++i) {
        vec2 offset = step_dir * float(i);

        // Positive direction
        vec2 uv_pos = v_uv + offset;
        float depth_pos = texture(u_depth_texture, uv_pos).r;
        float bilateral_pos = step(abs(center_depth - depth_pos), u_depth_threshold);
        float w_pos = weights[i] * bilateral_pos;
        result += texture(u_ssr_texture, uv_pos) * w_pos;
        total_weight += w_pos;

        // Negative direction
        vec2 uv_neg = v_uv - offset;
        float depth_neg = texture(u_depth_texture, uv_neg).r;
        float bilateral_neg = step(abs(center_depth - depth_neg), u_depth_threshold);
        float w_neg = weights[i] * bilateral_neg;
        result += texture(u_ssr_texture, uv_neg) * w_neg;
        total_weight += w_neg;
    }

    out_color = result / max(total_weight, 0.001);
}
