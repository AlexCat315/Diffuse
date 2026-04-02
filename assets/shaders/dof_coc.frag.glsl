#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_coc;

layout(set = 2, binding = 0) uniform sampler2D u_color;
layout(set = 2, binding = 1) uniform sampler2D u_depth;

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

float getLinearDepth(vec2 uv) {
    float depth = texture(u_depth, uv).r;
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = dof.u_inv_projection * clipPos;
    return -viewPos.z / viewPos.w;
}

void main() {
    float linearDepth = getLinearDepth(v_uv);

    float distanceFromFocus = abs(linearDepth - dof.u_focus_distance);
    float coc = distanceFromFocus / dof.u_focus_range;
    coc = clamp(coc, 0.0, 1.0);

    if (linearDepth < dof.u_near_blur) {
        coc = 1.0;
    } else if (linearDepth > dof.u_far_blur) {
        coc = 1.0;
    }

    out_coc = vec4(coc * dof.u_bokeh_radius, 0.0, 0.0, 1.0);
}
