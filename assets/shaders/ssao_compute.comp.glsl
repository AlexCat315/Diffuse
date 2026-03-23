#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D u_depth;
layout(set = 0, binding = 1) uniform sampler2D u_noise;

layout(set = 1, binding = 0, r8) uniform writeonly image2D u_output;

layout(set = 2, binding = 0, std140) uniform SSAOUniforms {
    mat4 u_projection;
    mat4 u_inv_projection;
    mat4 u_view;
    mat4 u_inv_view;
    vec2 u_resolution;
    float u_radius;
    float u_bias;
    float u_intensity;
    float u_power;
    uint u_kernel_size;
    vec2 u_noise_scale;
    vec2 u_padding;
} ssao;

vec3 getViewPos(vec2 uv, float depth) {
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = ssao.u_inv_projection * clipPos;
    return viewPos.xyz / viewPos.w;
}

vec3 reconstructNormal(vec3 viewPos, vec2 uv) {
    vec2 texel = 1.0 / ssao.u_resolution;

    float dL = texture(u_depth, uv + vec2(-texel.x, 0.0)).r;
    float dR = texture(u_depth, uv + vec2( texel.x, 0.0)).r;
    float dT = texture(u_depth, uv + vec2(0.0, -texel.y)).r;
    float dB = texture(u_depth, uv + vec2(0.0,  texel.y)).r;

    vec3 posL = getViewPos(uv + vec2(-texel.x, 0.0), dL);
    vec3 posR = getViewPos(uv + vec2( texel.x, 0.0), dR);
    vec3 posT = getViewPos(uv + vec2(0.0, -texel.y), dT);
    vec3 posB = getViewPos(uv + vec2(0.0,  texel.y), dB);

    vec3 dx = (abs(posL.z - viewPos.z) < abs(posR.z - viewPos.z))
              ? (viewPos - posL) : (posR - viewPos);
    vec3 dy = (abs(posT.z - viewPos.z) < abs(posB.z - viewPos.z))
              ? (viewPos - posT) : (posB - viewPos);

    return normalize(cross(dx, dy));
}

vec3 sampleKernel(int i) {
    const vec3 samples[32] = vec3[](
        vec3( 0.0481, -0.0447,  0.0500), vec3( 0.0143,  0.0371,  0.0780),
        vec3(-0.0415,  0.0187,  0.0880), vec3( 0.0404, -0.0135,  0.1200),
        vec3(-0.0341,  0.0398,  0.1400), vec3( 0.0415,  0.0175,  0.1800),
        vec3(-0.0192, -0.0335,  0.2100), vec3(-0.0151,  0.0448,  0.2400),
        vec3( 0.0849, -0.0467,  0.0610), vec3(-0.0609, -0.0539,  0.0830),
        vec3( 0.0699,  0.0054,  0.1100), vec3(-0.0234,  0.0900,  0.0720),
        vec3(-0.0886, -0.0069,  0.0530), vec3( 0.0550,  0.0834,  0.0440),
        vec3(-0.0862,  0.0399,  0.0360), vec3( 0.0980, -0.0210,  0.0320),
        vec3( 0.1360,  0.0753,  0.0880), vec3(-0.1120, -0.0900,  0.1020),
        vec3( 0.0990,  0.1450,  0.0650), vec3(-0.1580,  0.0280,  0.0750),
        vec3( 0.0370, -0.1620,  0.0930), vec3(-0.0540,  0.1550,  0.0850),
        vec3( 0.1780, -0.0320,  0.0480), vec3(-0.1250, -0.1330,  0.0570),
        vec3( 0.2150,  0.0890,  0.1250), vec3(-0.1800, -0.1650,  0.1450),
        vec3( 0.2550,  0.0120,  0.0680), vec3(-0.0980,  0.2350,  0.0820),
        vec3( 0.1200, -0.2480,  0.1100), vec3(-0.2800,  0.0850,  0.0950),
        vec3( 0.3100, -0.1200,  0.0520), vec3(-0.2100, -0.2600,  0.1300)
    );
    return samples[i];
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ivec2(ssao.u_resolution);

    if (pixel.x >= size.x || pixel.y >= size.y) return;

    vec2 uv = (vec2(pixel) + 0.5) / ssao.u_resolution;

    float depth = texture(u_depth, uv).r;
    if (depth >= 1.0) {
        imageStore(u_output, pixel, vec4(1.0));
        return;
    }

    vec3 viewPos = getViewPos(uv, depth);
    vec3 normal = reconstructNormal(viewPos, uv);

    vec3 randomVec = texture(u_noise, uv * ssao.u_noise_scale).xyz * 2.0 - 1.0;
    vec3 tangent = normalize(randomVec - normal * dot(randomVec, normal));
    vec3 bitangent = cross(normal, tangent);
    mat3 TBN = mat3(tangent, bitangent, normal);

    float occlusion = 0.0;
    int kernelSize = int(min(ssao.u_kernel_size, 32u));

    for (int i = 0; i < kernelSize; ++i) {
        vec3 sampleVec = TBN * sampleKernel(i);
        vec3 samplePos = viewPos + sampleVec * ssao.u_radius;

        vec4 offset = ssao.u_projection * vec4(samplePos, 1.0);
        offset.xyz /= offset.w;
        offset.xyz = offset.xyz * 0.5 + 0.5;

        if (offset.x < 0.0 || offset.x > 1.0 || offset.y < 0.0 || offset.y > 1.0) continue;

        float sampleDepth = texture(u_depth, offset.xy).r;
        vec3 sampleViewPos = getViewPos(offset.xy, sampleDepth);

        float rangeCheck = smoothstep(0.0, 1.0, ssao.u_radius / (abs(viewPos.z - sampleViewPos.z) + 0.001));
        occlusion += (sampleViewPos.z >= samplePos.z + ssao.u_bias ? 1.0 : 0.0) * rangeCheck;
    }

    float ao = 1.0 - (occlusion / float(kernelSize));
    ao = pow(clamp(ao, 0.0, 1.0), ssao.u_power);

    // Cross-bilateral blur (4-tap)
    float blur_ao = ao;
    float total_weight = 1.0;
    vec2 texel = 1.0 / ssao.u_resolution;
    float depth_threshold = 0.001;

    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 sample_uv = uv + vec2(float(x), float(y)) * texel;
            float neighbor_depth = texture(u_depth, sample_uv).r;
            float depth_diff = abs(depth - neighbor_depth);
            float w = exp(-depth_diff / depth_threshold) * 0.25;
            blur_ao += ao * w;
            total_weight += w;
        }
    }
    blur_ao /= total_weight;

    float result = mix(1.0, blur_ao, ssao.u_intensity);
    imageStore(u_output, pixel, vec4(result));
}
