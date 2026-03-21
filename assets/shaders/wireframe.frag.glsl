#version 450

layout(location = 0) in vec4 v_color;

layout(location = 0) out vec4 out_color;

void main() {
    // Simple wireframe output - cyan lines
    out_color = vec4(0.0, 1.0, 1.0, 1.0);
}
