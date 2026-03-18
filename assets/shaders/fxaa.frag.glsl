#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_color_map;

float luminance(vec3 color) {
    return dot(color, vec3(0.299, 0.587, 0.114));
}

void main() {
    vec2 texel = 1.0 / vec2(textureSize(u_color_map, 0));

    vec3 rgb_m = texture(u_color_map, v_uv).rgb;
    vec3 rgb_n = texture(u_color_map, v_uv + vec2(0.0, -texel.y)).rgb;
    vec3 rgb_s = texture(u_color_map, v_uv + vec2(0.0, texel.y)).rgb;
    vec3 rgb_w = texture(u_color_map, v_uv + vec2(-texel.x, 0.0)).rgb;
    vec3 rgb_e = texture(u_color_map, v_uv + vec2(texel.x, 0.0)).rgb;

    float luma_m = luminance(rgb_m);
    float luma_n = luminance(rgb_n);
    float luma_s = luminance(rgb_s);
    float luma_w = luminance(rgb_w);
    float luma_e = luminance(rgb_e);

    float luma_min = min(luma_m, min(min(luma_n, luma_s), min(luma_w, luma_e)));
    float luma_max = max(luma_m, max(max(luma_n, luma_s), max(luma_w, luma_e)));
    float range = luma_max - luma_min;

    if (range < max(0.0312, luma_max * 0.125)) {
        out_color = vec4(rgb_m, 1.0);
        return;
    }

    vec2 dir;
    dir.x = -((luma_n + luma_s) - 2.0 * luma_m);
    dir.y = (luma_w + luma_e) - 2.0 * luma_m;

    float dir_reduce = max((luma_n + luma_s + luma_w + luma_e) * 0.25 * 0.0312, 0.0078125);
    float rcp_dir_min = 1.0 / (min(abs(dir.x), abs(dir.y)) + dir_reduce);
    dir = clamp(dir * rcp_dir_min, vec2(-8.0), vec2(8.0)) * texel;

    vec3 rgb_a = 0.5 * (
        texture(u_color_map, v_uv + dir * (1.0 / 3.0 - 0.5)).rgb +
        texture(u_color_map, v_uv + dir * (2.0 / 3.0 - 0.5)).rgb
    );
    vec3 rgb_b = rgb_a * 0.5 + 0.25 * (
        texture(u_color_map, v_uv + dir * -0.5).rgb +
        texture(u_color_map, v_uv + dir * 0.5).rgb
    );

    float luma_b = luminance(rgb_b);
    vec3 result = (luma_b < luma_min || luma_b > luma_max) ? rgb_a : rgb_b;
    out_color = vec4(result, 1.0);
}
