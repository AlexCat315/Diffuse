#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;
layout(location = 3) in vec2 in_uv;

layout(set = 1, binding = 0, std140) uniform VertexUniforms {
    mat4 u_view_projection;
    mat4 u_model;
} vertex_uniforms;

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec3 v_world_normal;
layout(location = 3) out vec3 v_world_position;

void main() {
    v_color = in_color;
    v_uv = in_uv;

    vec4 world_position = vertex_uniforms.u_model * vec4(in_position, 1.0);
    v_world_position = world_position.xyz;
    v_world_normal = normalize((vertex_uniforms.u_model * vec4(in_normal, 0.0)).xyz);
    gl_Position = vertex_uniforms.u_view_projection * world_position;
    gl_Position.y = -gl_Position.y;
}
