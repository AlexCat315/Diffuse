#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D u_depth;
layout(set = 0, binding = 1) uniform sampler2D u_hdr_color;
layout(set = 0, binding = 2) uniform sampler2D u_noise;

layout(set = 1, binding = 0, rgba16f) uniform writeonly image2D u_output;

layout(set = 2, binding = 0, std140) uniform SSGIUniforms {
    mat4 u_projection;
    mat4 u_inv_projection;
    mat4 u_view;
    mat4 u_inv_view;
    vec2 u_resolution;
    float u_radius;
    float u_intensity;
    float u_bias;
    uint u_ray_count;
    uint u_step_count;
    float u_padding;
} ssgi;

vec3 getViewPos(vec2 uv, float depth) {
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = ssgi.u_inv_projection * clipPos;
    return viewPos.xyz / viewPos.w;
}

vec3 reconstructNormal(vec3 viewPos, vec2 uv) {
    vec2 texel = 1.0 / ssgi.u_resolution;
    float dL = texture(u_depth, uv + vec2(-texel.x, 0.0)).r;
    float dR = texture(u_depth, uv + vec2( texel.x, 0.0)).r;
    float dT = texture(u_depth, uv + vec2(0.0, -texel.y)).r;
    float dB = texture(u_depth, uv + vec2(0.0,  texel.y)).r;

    vec3 posL = getViewPos(uv + vec2(-texel.x, 0.0), dL);
    vec3 posR = getViewPos(uv + vec2( texel.x, 0.0), dR);
    vec3 posT = getViewPos(uv + vec2(0.0, -texel.y), dT);
    vec3 posB = getViewPos(uv + vec2(0.0,  texel.y), dB);

    vec3 dx = (abs(posL.z - viewPos.z) < abs(posR.z - viewPos.z)) ? (viewPos - posL) : (posR - viewPos);
    vec3 dy = (abs(posT.z - viewPos.z) < abs(posB.z - viewPos.z)) ? (viewPos - posT) : (posB - viewPos);

    return normalize(cross(dx, dy));
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

vec3 getSampleDirection(vec2 uv, float index, vec3 normal) {
    vec2 noise_uv = uv * ssgi.u_resolution / 4.0;
    vec3 randomVec = texture(u_noise, noise_uv).xyz * 2.0 - 1.0;
    randomVec.z += hash(uv + index);
    randomVec = normalize(randomVec);

    vec3 tangent = normalize(randomVec - normal * dot(randomVec, normal));
    vec3 bitangent = cross(normal, tangent);
    mat3 TBN = mat3(tangent, bitangent, normal);

    float r1 = fract(hash(uv + index * 1.3) + 0.1);
    float r2 = fract(hash(uv + index * 1.7) + 0.2);
    float phi = 2.0 * 3.14159265 * r1;
    float r = sqrt(r2);
    float z = sqrt(1.0 - r2);
    vec3 localDir = vec3(r * cos(phi), r * sin(phi), z);

    return normalize(TBN * localDir);
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ivec2(ssgi.u_resolution);
    if (pixel.x >= size.x || pixel.y >= size.y) return;

    vec2 uv = (vec2(pixel) + 0.5) / ssgi.u_resolution;
    float depth = texture(u_depth, uv).r;
    if (depth >= 1.0) {
        imageStore(u_output, pixel, vec4(0.0));
        return;
    }

    vec3 viewPos = getViewPos(uv, depth);
    vec3 normal = reconstructNormal(viewPos, uv);

    vec3 indirectDiffuse = vec3(0.0);
    float totalWeight = 0.0;

    for(uint i = 0; i < ssgi.u_ray_count; ++i) {
        vec3 rayDir = getSampleDirection(uv, float(i), normal);

        float stepSize = ssgi.u_radius / float(ssgi.u_step_count);
        vec3 currentPos = viewPos + normal * 0.05; // Offset to avoid self-intersection
        vec3 sampleColor = vec3(0.0);
        float hitWeight = 0.0;

        for(uint j = 0; j < ssgi.u_step_count; ++j) {
            currentPos += rayDir * stepSize;

            vec4 offset = ssgi.u_projection * vec4(currentPos, 1.0);
            offset.xyz /= offset.w;
            offset.xyz = offset.xyz * 0.5 + 0.5;

            if(offset.x < 0.0 || offset.x > 1.0 || offset.y < 0.0 || offset.y > 1.0) break;

            float sampleDepth = texture(u_depth, offset.xy).r;
            vec3 sampleViewPos = getViewPos(offset.xy, sampleDepth);

            float depthDiff = currentPos.z - sampleViewPos.z;
            if(depthDiff > ssgi.u_bias && depthDiff < ssgi.u_radius * 0.2) {
                sampleColor = texture(u_hdr_color, offset.xy).rgb;
                hitWeight = 1.0 - smoothstep(0.0, ssgi.u_radius, length(currentPos - viewPos));
                break;
            }
        }

        indirectDiffuse += sampleColor * hitWeight * max(dot(normal, rayDir), 0.0);
        totalWeight += 1.0;
    }

    if (totalWeight > 0.0) {
        indirectDiffuse /= totalWeight;
    }

    // Bilateral blur approximation inline for performance (like SSAO)
    vec3 blur_ssgi = indirectDiffuse;
    float blur_weight = 1.0;
    vec2 texel = 1.0 / ssgi.u_resolution;
    float depth_threshold = 0.001;

    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 sample_uv = uv + vec2(float(x), float(y)) * texel;
            float neighbor_depth = texture(u_depth, sample_uv).r;
            float depth_diff = abs(depth - neighbor_depth);
            float w = exp(-depth_diff / depth_threshold) * 0.25;
            blur_ssgi += indirectDiffuse * w;
            blur_weight += w;
        }
    }
    blur_ssgi /= blur_weight;

    blur_ssgi *= ssgi.u_intensity;
    imageStore(u_output, pixel, vec4(blur_ssgi, 1.0));
}
