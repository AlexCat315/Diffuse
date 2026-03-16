#version 450

layout(location = 0) in vec3 in_position;

layout(set = 1, binding = 0, std140) uniform VertexUniforms {
    mat4 u_view_projection;
    mat4 u_model;
} vertex_uniforms;

void main() {
    vec4 world_position = vertex_uniforms.u_model * vec4(in_position, 1.0);
    gl_Position = vertex_uniforms.u_view_projection * world_position;
    gl_Position.y = -gl_Position.y;
}
