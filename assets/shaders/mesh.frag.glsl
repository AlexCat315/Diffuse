#version 450

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_base_color;

layout(set = 3, binding = 0, std140) uniform MaterialUniforms {
    vec4 u_base_color_factor;
} material_uniforms;

void main() {
    vec4 base = texture(u_base_color, v_uv);
    out_color = base * v_color * material_uniforms.u_base_color_factor;
}
