#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_shadow_mask;
layout(set = 3, binding = 0, std140) uniform ShadowParams {
    // x: strength (0=无阴影, 1=完全阴影), y: ambient_floor (最小可见度)
    vec4 u_shadow_params;
};

void main() {
    float vis = texture(u_shadow_mask, v_uv).r;
    float strength = u_shadow_params.x;
    float ambient_floor = u_shadow_params.y;

    // 应用阴影强度: 在完全可见(1.0)和原始可见度之间插值
    vis = mix(1.0, vis, strength);
    // 保留环境光底色，避免阴影区域全黑
    vis = max(vis, ambient_floor);
    out_color = vec4(vis, vis, vis, 1.0);
}
