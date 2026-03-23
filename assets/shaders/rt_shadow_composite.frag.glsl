#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_shadow_mask;

void main() {
    float vis = texture(u_shadow_mask, v_uv).r;
    // 保留环境光底色，避免阴影区域全黑
    vis = max(vis, 0.15);
    out_color = vec4(vis, vis, vis, 1.0);
}
