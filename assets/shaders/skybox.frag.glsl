#version 450

layout(location = 0) in vec3 v_world_dir;
layout(location = 0) out vec4 out_color;

layout(set = 1, binding = 0) uniform sampler2D u_environment_map;

const vec2 invAtan = vec2(0.1591, 0.3183);

vec2 sampleSphericalMap(vec3 v) {
    vec2 uv = vec2(atan(v.z, v.x), asin(v.y));
    uv *= invAtan;
    uv += 0.5;
    // Metal texture origin is top-left (uv.y=0 = top of image).
    // Standard equirectangular maps store sky at top row.
    // Without this flip, +Y (sky) maps to uv.y=1 (bottom) → upside-down.
    uv.y = 1.0 - uv.y;
    return uv;
}

void main() {
    vec3 dir = normalize(v_world_dir);
    vec2 uv = sampleSphericalMap(dir);

    vec3 color = texture(u_environment_map, uv).rgb;

    // Simple exposure + Reinhard tonemapping for LDR output.
    // Without this, HDR environment values > 1.0 clip to pure white.
    float exposure = 1.0;
    color *= exposure;
    color = color / (color + vec3(1.0)); // Reinhard

    out_color = vec4(color, 1.0);
}
