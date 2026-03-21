#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec2 v_uv_history;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_current;
layout(set = 2, binding = 1) uniform sampler2D u_history;
layout(set = 2, binding = 2) uniform sampler2D u_velocity;
layout(set = 2, binding = 3) uniform sampler2D u_depth;

layout(set = 3, binding = 0, std140) uniform TAAUniforms {
    mat4 u_projection;
    mat4 u_inv_projection;
    mat4 u_view;
    mat4 u_prev_view;
    vec2 u_resolution;
    vec2 u_jitter;
    float u_blend_factor;
    float u_motion_blur_scale;
    float u_feedback_min;
    float u_feedback_max;
} taa;

vec3 RGBToYCoCg(vec3 rgb) {
    float y = 0.25 * rgb.r + 0.5 * rgb.g + 0.25 * rgb.b;
    float co = 0.5 * rgb.r - 0.5 * rgb.b;
    float cg = -0.25 * rgb.r + 0.5 * rgb.g - 0.25 * rgb.b;
    return vec3(y, co, cg);
}

vec3 YCoCgToRGB(vec3 ycocg) {
    float r = ycocg.x + ycocg.y - ycocg.z;
    float g = ycocg.x + ycocg.z;
    float b = ycocg.x - ycocg.y - ycocg.z;
    return vec3(r, g, b);
}

vec3 clipAABB(vec3 color, vec3 min_color, vec3 max_color) {
    vec3 center = 0.5 * (max_color + min_color);
    vec3 extents = 0.5 * (max_color - min_color);
    vec3 offset = color - center;
    vec3 ts = abs(extents) / max(abs(offset), vec3(0.0001));
    float t = min(min(ts.x, ts.y), ts.z);
    t = min(t, 1.0);
    return center + offset * t;
}

void main() {
    float depth = texture(u_depth, v_uv).r;
    vec2 velocity = texture(u_velocity, v_uv).rg * u_motion_blur_scale;
    vec2 uv_history = v_uv - velocity;

    if (uv_history.x < 0.0 || uv_history.x > 1.0 || uv_history.y < 0.0 || uv_history.y > 1.0) {
        out_color = texture(u_current, v_uv);
        return;
    }

    vec3 current_color = texture(u_current, v_uv).rgb;
    vec3 history_color = texture(u_history, uv_history).rgb;

    current_color = RGBToYCoCg(current_color);
    history_color = RGBToYCoCg(history_color);

    vec3 min_color = current_color;
    vec3 max_color = current_color;

    vec2 texel_size = 1.0 / u_resolution;
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(-texel_size.x, -texel_size.y)).rgb));
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(0.0, -texel_size.y)).rgb));
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(texel_size.x, -texel_size.y)).rgb));
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(-texel_size.x, 0.0)).rgb));
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(texel_size.x, 0.0)).rgb));
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(-texel_size.x, texel_size.y)).rgb));
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(0.0, texel_size.y)).rgb));
    min_color = min(min_color, RGBToYCoCg(texture(u_current, v_uv + vec2(texel_size.x, texel_size.y)).rgb));

    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(-texel_size.x, -texel_size.y)).rgb));
    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(0.0, -texel_size.y)).rgb));
    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(texel_size.x, -texel_size.y)).rgb));
    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(-texel_size.x, 0.0)).rgb));
    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(texel_size.x, 0.0)).rgb));
    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(-texel_size.x, texel_size.y)).rgb));
    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(0.0, texel_size.y)).rgb));
    max_color = max(max_color, RGBToYCoCg(texture(u_current, v_uv + vec2(texel_size.x, texel_size.y)).rgb));

    history_color = clipAABB(history_color, min_color, max_color);

    float motion_length = length(velocity);
    float feedback = mix(u_feedback_max, u_feedback_min, min(motion_length * 100.0, 1.0));

    vec3 result = mix(current_color, history_color, feedback);
    result = YCoCgToRGB(result);

    out_color = vec4(result, 1.0);
}
