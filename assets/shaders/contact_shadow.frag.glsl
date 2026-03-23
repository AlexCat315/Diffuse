#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out float out_shadow;

layout(set = 2, binding = 0) uniform sampler2D u_depth;

layout(set = 3, binding = 0, std140) uniform ContactShadowUniforms {
    mat4 u_projection;
    mat4 u_inv_projection;
    mat4 u_view;
    vec4 u_light_direction;   // xyz: world-space light dir (toward surface)
    vec2 u_resolution;
    float u_max_distance;     // world-space ray march distance
    float u_thickness;        // depth thickness threshold
    float u_intensity;        // shadow darkness
    float u_bias;             // initial ray offset
    int u_num_steps;          // ray march step count
    float u_padding;
} params;

// Reconstruct view-space position from depth and UV
vec3 viewPosFromDepth(vec2 uv, float depth) {
    // NDC: x,y in [-1,1], z in [0,1]
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 view_pos = params.u_inv_projection * ndc;
    return view_pos.xyz / view_pos.w;
}

void main() {
    float depth = texture(u_depth, v_uv).r;

    // Sky pixels — no contact shadow
    if (depth >= 1.0) {
        out_shadow = 1.0;
        return;
    }

    // Reconstruct view-space position
    vec3 view_pos = viewPosFromDepth(v_uv, depth);

    // Transform light direction to view space
    vec3 light_dir_world = normalize(params.u_light_direction.xyz);
    vec3 light_dir_view = normalize((params.u_view * vec4(light_dir_world, 0.0)).xyz);

    // Ray march direction: toward light (negate because light_direction points toward surface)
    vec3 ray_dir = normalize(-light_dir_view);

    // Scale step size to max_distance
    float step_size = params.u_max_distance / float(params.u_num_steps);

    // Start with a small bias offset to avoid self-shadowing
    vec3 ray_pos = view_pos + ray_dir * params.u_bias;

    float occlusion = 0.0;

    for (int i = 0; i < params.u_num_steps; ++i) {
        ray_pos += ray_dir * step_size;

        // Project ray position to screen space
        vec4 proj = params.u_projection * vec4(ray_pos, 1.0);
        proj.xyz /= proj.w;
        vec2 sample_uv = proj.xy * 0.5 + 0.5;
        // Flip Y to match texture coordinates
        sample_uv.y = 1.0 - sample_uv.y;

        // Out of screen bounds — stop
        if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) {
            break;
        }

        // Sample scene depth at this screen position
        float scene_depth = texture(u_depth, sample_uv).r;
        vec3 scene_view_pos = viewPosFromDepth(sample_uv, scene_depth);

        // Compare depths: if the ray is behind scene geometry within thickness threshold, occluded
        float depth_diff = ray_pos.z - scene_view_pos.z;
        if (depth_diff > 0.0 && depth_diff < params.u_thickness) {
            // Fade occlusion based on distance along ray (closer = stronger)
            float fade = 1.0 - float(i) / float(params.u_num_steps);
            occlusion = max(occlusion, fade);
            break;
        }
    }

    out_shadow = 1.0 - occlusion * params.u_intensity;
}
