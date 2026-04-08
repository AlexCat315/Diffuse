#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

layout(set = 1, binding = 0, std140) uniform VertexUniforms {
    vec2 u_viewport_size;
    vec2 _pad;
} uniforms;

void main() {
    // Convert pixel coordinates to NDC: [0, viewport] -> [-1, 1]
    vec2 ndc = (in_position / uniforms.u_viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;  // Flip Y for top-left origin
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
    v_color = in_color;
}
