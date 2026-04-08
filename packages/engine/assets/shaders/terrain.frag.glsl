#version 450

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in float v_height;

layout(location = 0) out vec4 out_color;

void main() {
    // Height-based coloring (grass → rock → snow).
    vec3 grass = vec3(0.22, 0.55, 0.15);
    vec3 rock  = vec3(0.45, 0.40, 0.35);
    vec3 snow  = vec3(0.92, 0.93, 0.95);

    float t = clamp(v_height / 50.0, 0.0, 1.0);
    vec3 base_color;
    if (t < 0.4) {
        base_color = mix(grass, rock, t / 0.4);
    } else {
        base_color = mix(rock, snow, (t - 0.4) / 0.6);
    }

    // Simple directional light (sun).
    vec3 light_dir = normalize(vec3(0.5, 0.8, 0.3));
    float ndl = max(dot(v_normal, light_dir), 0.0);
    vec3 ambient = base_color * 0.25;
    vec3 diffuse = base_color * ndl * 0.75;

    out_color = vec4(ambient + diffuse, 1.0);
}
