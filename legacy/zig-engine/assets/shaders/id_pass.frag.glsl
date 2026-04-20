#version 450

layout(location = 0) out vec4 out_color;

layout(set = 3, binding = 0, std140) uniform IdPassUniforms {
    vec4 u_entity_color;
} id_uniforms;

void main() {
    out_color = id_uniforms.u_entity_color;
}
