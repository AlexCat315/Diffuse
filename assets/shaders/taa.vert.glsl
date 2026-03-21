#version 450

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec2 v_uv_history;

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

void main() {
    v_uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(v_uv * 2.0 - 1.0, 0.0, 1.0);
    v_uv.y = 1.0 - v_uv.y;
    v_uv_history = v_uv - taa.u_jitter;
}
