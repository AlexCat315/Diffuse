#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_color;

layout(location = 0) out vec4 v_color;

layout(set = 0, binding = 0, std140) uniform VertexUniforms {
    mat4 view_projection;
    mat4 model;
    uvec4 skinning_meta;
    mat4 skin_matrices[4];
} vertex_uniforms;

void main() {
    vec4 world_pos = vertex_uniforms.model * vec4(in_position, 1.0);
    gl_Position = vertex_uniforms.view_projection * world_pos;
    v_color = in_color;
}
