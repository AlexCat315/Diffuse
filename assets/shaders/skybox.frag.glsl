#version 450

layout(location = 0) in vec3 v_world_dir;
layout(location = 0) out vec4 out_color;

layout(set = 1, binding = 0) uniform sampler2D u_environment_map;

const vec2 invAtan = vec2(0.1591, 0.3183);

vec2 sampleSphericalMap(vec3 v) {
    vec2 uv = vec2(atan(v.z, v.x), asin(v.y));
    uv *= invAtan;
    uv += 0.5;
    return uv;
}

void main() {
    vec3 dir = normalize(v_world_dir);
    vec2 uv = sampleSphericalMap(dir);

    // In many engines, environment maps are flipped horizontally or vertically.
    // If it's flipped, we can adjust here.

    vec3 color = texture(u_environment_map, uv).rgb;

    // No tonemapping here, since we are rendering to an HDR buffer
    // and the tonemap pass will handle it later!

    out_color = vec4(color, 1.0);
}
