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

vec2 getScreenPos(vec3 viewPos) {
    vec4 clipPos = ssr.u_projection * vec4(viewPos, 1.0);
    vec3 ndc = clipPos.xyz / clipPos.w;
    return ndc.xy * 0.5 + 0.5;
}

// Binary search refinement for precise hit location
vec2 binarySearch(vec3 rayStart, vec3 rayDir, float tHit) {
    float lo = tHit - 1.0;
    float hi = tHit;

    for (int i = 0; i < 8; ++i) {
        float mid = (lo + hi) * 0.5;
        vec3 pos = rayStart + rayDir * mid;
        vec2 screenPos = getScreenPos(pos);

        if (screenPos.x < 0.0 || screenPos.x > 1.0 || screenPos.y < 0.0 || screenPos.y > 1.0) {
            hi = mid;
            continue;
        }

        float sampleDepth = texture(u_depth, screenPos).r;
        vec3 sampleViewPos = getViewPos(screenPos, sampleDepth);
        float depthDiff = sampleViewPos.z - pos.z;

        if (depthDiff > 0.0 && depthDiff < ssr.u_ray_thickness) {
            hi = mid; // We're behind surface, reduce t
        } else {
            lo = mid; // We're in front, increase t
        }
    }

    vec3 finalPos = rayStart + rayDir * ((lo + hi) * 0.5);
    return getScreenPos(finalPos);
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

    // Adaptive-stride ray marching: large steps far away, fine steps up close
    float stepCount = ssr.u_stride;
    float baseStep = ssr.u_ray_max_distance / stepCount;

    vec3 rayPos = viewPos;
    vec2 hitUV = vec2(0.0);
    bool hit = false;
    float hitT = 0.0;

    for (float i = 0.0; i < stepCount; i += 1.0) {
        // Accelerating step size: larger steps at greater distances
        float stepScale = 1.0 + i * 0.15;
        rayPos += reflectDir * baseStep * stepScale;

        vec2 screenPos = getScreenPos(rayPos);
        if (screenPos.x < 0.0 || screenPos.x > 1.0 || screenPos.y < 0.0 || screenPos.y > 1.0) {
            break;
        }

        float sampleDepth = texture(u_depth, screenPos).r;
        vec3 sampleViewPos = getViewPos(screenPos, sampleDepth);

        float depthDiff = sampleViewPos.z - rayPos.z;
        if (depthDiff > 0.0 && depthDiff < ssr.u_ray_thickness) {
            hit = true;
            hitT = i;
            break;
        }
    }

    if (!hit) {
        out_reflection = vec4(0.0);
        return;
    }

    // Binary search refinement for sub-pixel precision
    hitUV = binarySearch(viewPos, reflectDir, hitT * baseStep * (1.0 + hitT * 0.15));
    if (hitUV.x < 0.0 || hitUV.x > 1.0 || hitUV.y < 0.0 || hitUV.y > 1.0) {
        out_reflection = vec4(0.0);
        return;
    }

    vec3 reflectionColor = texture(u_color, hitUV).rgb;

    // Screen edge fade (all 4 edges)
    float fade = 1.0;
    fade *= smoothstep(0.0, ssr.u_edge_fade, hitUV.x);
    fade *= smoothstep(0.0, ssr.u_edge_fade, 1.0 - hitUV.x);
    fade *= smoothstep(0.0, ssr.u_edge_fade, hitUV.y);
    fade *= smoothstep(0.0, ssr.u_edge_fade, 1.0 - hitUV.y);

    // Distance attenuation
    float distanceFade = 1.0 - smoothstep(ssr.u_fade_distance * 0.5, ssr.u_fade_distance, length(viewPos));

    // Fresnel-weighted intensity: stronger reflections at grazing angles
    float NdotV = max(dot(normal, viewDir), 0.0);
    float fresnelFade = 1.0 - NdotV * 0.5;

    out_reflection = vec4(reflectionColor * ssr.u_intensity * fade * distanceFade * fresnelFade, 1.0);
}
