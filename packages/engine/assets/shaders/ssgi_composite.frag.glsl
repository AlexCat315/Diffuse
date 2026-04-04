#version 450

layout(location = 0) in vec2 v_uv;

layout(set = 0, binding = 0) uniform sampler2D u_ssgi_texture;

layout(set = 1, binding = 0, std140) uniform SSGICompositeUniforms {
    vec4 u_params; // x = intensity
} ssgi_composite_uniforms;

layout(location = 0) out vec4 o_color;

void main() {
    vec3 ssgi_color = texture(u_ssgi_texture, v_uv).rgb;
    o_color = vec4(ssgi_color * ssgi_composite_uniforms.u_params.x, 1.0);
}
