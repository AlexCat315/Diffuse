#version 450

layout(location = 0) out vec4 out_color;

layout(set = 3, binding = 0, std140) uniform GizmoUniforms {
    vec4 u_color;
} gizmo_uniforms;

void main() {
    out_color = gizmo_uniforms.u_color;
}
