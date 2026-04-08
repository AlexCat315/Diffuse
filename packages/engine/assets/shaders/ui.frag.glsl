#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_texture;

layout(set = 3, binding = 0, std140) uniform FragmentUniforms {
    int u_mode;  // 0 = solid color, 1 = textured, 2 = SDF text
    float u_sdf_threshold;
    float u_sdf_smoothing;
    float _pad;
} frag_uniforms;

void main() {
    if (frag_uniforms.u_mode == 0) {
        // Solid color (rect)
        out_color = v_color;
    } else if (frag_uniforms.u_mode == 1) {
        // Textured quad (image)
        vec4 tex = texture(u_texture, v_uv);
        out_color = tex * v_color;
    } else {
        // SDF text
        float dist = texture(u_texture, v_uv).r;
        float alpha = smoothstep(
            frag_uniforms.u_sdf_threshold - frag_uniforms.u_sdf_smoothing,
            frag_uniforms.u_sdf_threshold + frag_uniforms.u_sdf_smoothing,
            dist
        );
        out_color = vec4(v_color.rgb, v_color.a * alpha);
    }
}
