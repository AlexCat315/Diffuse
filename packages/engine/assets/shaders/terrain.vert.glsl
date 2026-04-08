#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;
layout(location = 3) in vec2 in_uv;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out float v_height;

layout(set = 0, binding = 0, std140) uniform VertexUniforms {
    mat4 view_projection;
    mat4 model;
    uvec4 skinning_meta;
    mat4 skin_matrices[4];
} vertex_uniforms;

void main() {
    vec4 world_pos = vertex_uniforms.model * vec4(in_position, 1.0);
    gl_Position = vertex_uniforms.view_projection * world_pos;
    v_normal = normalize(mat3(vertex_uniforms.model) * in_normal);
    v_uv = in_uv;
    v_height = in_position.y;
}
