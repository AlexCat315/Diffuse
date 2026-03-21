#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_reflection;

layout(set = 2, binding = 0) uniform sampler2D u_color;
layout(set = 2, binding = 1) uniform sampler2D u_depth;
layout(set = 2, binding = 2) uniform sampler2D u_normal;

layout(set = 3, binding = 0, std140) uniform SSRUniforms {
    mat4 u_projection;
    mat4 u_inv_projection;
    mat4 u_view;
    mat4 u_inv_view;
    vec2 u_resolution;
    float u_ray_step;
    float u_ray_max_distance;
    float u_ray_thickness;
    float u_intensity;
    float u_fade_distance;
    float u_edge_fade;
    float u_stride;
    float u_stride_z_cutoff;
} ssr;

vec3 getViewPos(vec2 uv, float depth) {
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = ssr.u_inv_projection * clipPos;
    return viewPos.xyz / viewPos.w;
}

vec3 getWorldPos(vec2 uv, float depth) {
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = ssr.u_inv_projection * clipPos;
    vec4 worldPos = ssr.u_inv_view * viewPos;
    return worldPos.xyz / worldPos.w;
}

vec2 getScreenPos(vec3 viewPos) {
    vec4 clipPos = ssr.u_projection * vec4(viewPos, 1.0);
    vec3 ndc = clipPos.xyz / clipPos.w;
    return ndc.xy * 0.5 + 0.5;
}

void main() {
    float depth = texture(u_depth, v_uv).r;
    if (depth >= 1.0) {
        out_reflection = vec4(0.0);
        return;
    }

    vec3 viewPos = getViewPos(v_uv, depth);
    vec3 normal = texture(u_normal, v_uv).rgb * 2.0 - 1.0;
    normal = normalize(mat3(ssr.u_view) * normal);

    vec3 viewDir = normalize(-viewPos);
    vec3 reflectDir = reflect(-viewDir, normal);

    if (reflectDir.z > 0.0) {
        out_reflection = vec4(0.0);
        return;
    }

    vec3 rayStart = viewPos;
    vec3 rayEnd = viewPos + reflectDir * ssr.u_ray_max_distance;

    vec2 startScreen = getScreenPos(rayStart);
    vec2 endScreen = getScreenPos(rayEnd);

    if (endScreen.x < 0.0 || endScreen.x > 1.0 || endScreen.y < 0.0 || endScreen.y > 1.0) {
        out_reflection = vec4(0.0);
        return;
    }

    float stepCount = ssr.u_stride;
    vec3 rayStep = (rayEnd - rayStart) / stepCount;
    vec3 rayPos = rayStart;

    vec2 hitUV = vec2(0.0);
    bool hit = false;

    for (float i = 0.0; i < stepCount; i += 1.0) {
        rayPos += rayStep;
        vec2 screenPos = getScreenPos(rayPos);

        if (screenPos.x < 0.0 || screenPos.x > 1.0 || screenPos.y < 0.0 || screenPos.y > 1.0) {
            break;
        }

        float sampleDepth = texture(u_depth, screenPos).r;
        vec3 sampleViewPos = getViewPos(screenPos, sampleDepth);

        float depthDiff = sampleViewPos.z - rayPos.z;
        if (depthDiff > 0.0 && depthDiff < ssr.u_ray_thickness) {
            hit = true;
            hitUV = screenPos;
            break;
        }
    }

    if (!hit) {
        out_reflection = vec4(0.0);
        return;
    }

    vec3 reflectionColor = texture(u_color, hitUV).rgb;

    float fade = 1.0;
    fade *= 1.0 - smoothstep(0.0, ssr.u_edge_fade, hitUV.x);
    fade *= 1.0 - smoothstep(1.0 - ssr.u_edge_fade, 1.0, hitUV.x);
    fade *= 1.0 - smoothstep(0.0, ssr.u_edge_fade, hitUV.y);
    fade *= 1.0 - smoothstep(1.0 - ssr.u_edge_fade, 1.0, hitUV.y);

    float distanceFade = 1.0 - smoothstep(ssr.u_fade_distance * 0.5, ssr.u_fade_distance, length(viewPos));

    out_reflection = vec4(reflectionColor * ssr.u_intensity * fade * distanceFade, 1.0);
}
