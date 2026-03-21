#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_color;
layout(set = 2, binding = 1) uniform sampler2D u_blur;
layout(set = 2, binding = 2) uniform sampler2D u_coc;

layout(set = 3, binding = 0, std140) uniform DOFUniforms {
    mat4 u_projection;
    mat4 u_inv_projection;
    vec2 u_resolution;
    float u_focus_distance;
    float u_focus_range;
    float u_blur_radius;
    float u_bokeh_radius;
    float u_near_blur;
    float u_far_blur;
    uint u_quality;
} dof;

void main() {
    vec3 sharp = texture(u_color, v_uv).rgb;
    vec3 blurred = texture(u_blur, v_uv).rgb;
    float coc = texture(u_coc, v_uv).r;

    float blend = smoothstep(0.0, dof.u_bokeh_radius, coc);

    out_color = vec4(mix(sharp, blurred, blend), 1.0);
}
