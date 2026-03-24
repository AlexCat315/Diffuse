#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out float out_shadow;

layout(set = 2, binding = 0) uniform sampler2D u_shadow_mask;
layout(set = 2, binding = 1) uniform sampler2D u_scene_depth;

layout(set = 3, binding = 0, std140) uniform RtShadowDenoiseUniforms {
    vec2 u_resolution;
    vec2 u_inv_resolution;
    vec4 u_filter_params; // x: spatial_sigma, y: depth_sharpness, z: kernel_radius
} denoise;

float spatialWeight(vec2 offset, float sigma) {
    float sigma2 = max(sigma * sigma, 0.0001);
    return exp(-dot(offset, offset) / (2.0 * sigma2));
}

void main() {
    float center_depth = texture(u_scene_depth, v_uv).r;
    if (center_depth >= 1.0) {
        out_shadow = 1.0;
        return;
    }

    float center_shadow = texture(u_shadow_mask, v_uv).r;
    float accum = center_shadow;
    float weight_sum = 1.0;

    int kernel_radius = int(clamp(denoise.u_filter_params.z, 1.0, 3.0));
    float spatial_sigma = max(denoise.u_filter_params.x, 0.5);
    float depth_sharpness = max(denoise.u_filter_params.y, 1.0);

    for (int y = -3; y <= 3; ++y) {
        for (int x = -3; x <= 3; ++x) {
            if (abs(x) > kernel_radius || abs(y) > kernel_radius || (x == 0 && y == 0)) {
                continue;
            }

            vec2 pixel_offset = vec2(float(x), float(y));
            vec2 sample_uv = clamp(v_uv + pixel_offset * denoise.u_inv_resolution, vec2(0.0), vec2(1.0));
            float sample_depth = texture(u_scene_depth, sample_uv).r;
            float sample_shadow = texture(u_shadow_mask, sample_uv).r;

            float relative_depth = abs(sample_depth - center_depth) / max(max(center_depth, sample_depth), 0.0001);
            float depth_weight = exp(-relative_depth * depth_sharpness);
            float weight = spatialWeight(pixel_offset, spatial_sigma) * depth_weight;

            accum += sample_shadow * weight;
            weight_sum += weight;
        }
    }

    out_shadow = clamp(accum / max(weight_sum, 0.0001), 0.0, 1.0);
}