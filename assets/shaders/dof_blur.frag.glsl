#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_color;
layout(set = 2, binding = 1) uniform sampler2D u_coc;

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

const float PI = 3.14159265359;

vec3 bokehBlur(vec2 uv, float radius, int quality) {
    if (radius < 0.5) {
        return texture(u_color, uv).rgb;
    }

    vec3 color = vec3(0.0);
    float total_weight = 0.0;

    float golden_angle = 2.39996323;
    float angle = 0.0;

    int samples = quality * quality * 4;

    for (int i = 0; i < samples; ++i) {
        float r = sqrt(float(i)) / sqrt(float(samples));
        float theta = angle;

        vec2 offset = vec2(cos(theta), sin(theta)) * r * radius / dof.u_resolution;
        vec2 sample_uv = uv + offset;

        float sample_coc = texture(u_coc, sample_uv).r;
        float weight = max(0.001, sample_coc);

        color += texture(u_color, sample_uv).rgb * weight;
        total_weight += weight;

        angle += golden_angle;
    }

    return color / total_weight;
}

void main() {
    float coc = texture(u_coc, v_uv).r;

    if (coc < 0.5) {
        out_color = vec4(texture(u_color, v_uv).rgb, 1.0);
        return;
    }

    vec3 blurred = bokehBlur(v_uv, coc * dof.u_blur_radius / dof.u_bokeh_radius, int(dof.u_quality));

    out_color = vec4(blurred, 1.0);
}
