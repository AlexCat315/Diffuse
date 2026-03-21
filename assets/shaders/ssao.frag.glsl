#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out float out_ao;

layout(set = 2, binding = 0) uniform sampler2D u_depth;
layout(set = 2, binding = 1) uniform sampler2D u_noise;

layout(set = 3, binding = 0, std140) uniform SSAOUniforms {
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
} ssao;

vec3 getViewPos(vec2 uv, float depth) {
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = ssao.u_inv_projection * clipPos;
    return viewPos.xyz / viewPos.w;
}

vec3 sampleKernel(int i) {
    vec3 samples[64];
    samples[0] = vec3(0.04977, -0.04471, 0.04996);
    samples[1] = vec3(0.01432, 0.03711, 0.02240);
    samples[2] = vec3(-0.04152, 0.01869, 0.02580);
    samples[3] = vec3(0.04038, -0.01349, 0.03700);
    samples[4] = vec3(-0.03408, 0.03983, 0.00930);
    samples[5] = vec3(0.04148, 0.01745, 0.01490);
    samples[6] = vec3(-0.01923, -0.03348, 0.04720);
    samples[7] = vec3(-0.01508, 0.04484, 0.02300);
    samples[8] = vec3(0.02687, -0.04673, 0.02490);
    samples[9] = vec3(-0.03088, -0.03387, 0.04170);
    samples[10] = vec3(0.04987, 0.00377, 0.01470);
    samples[11] = vec3(-0.01339, 0.04997, 0.01180);
    samples[12] = vec3(-0.04857, -0.00691, 0.01270);
    samples[13] = vec3(0.02500, 0.04335, 0.00840);
    samples[14] = vec3(-0.04618, 0.01987, 0.00560);
    samples[15] = vec3(0.04797, -0.01095, 0.00620);
    samples[16] = vec3(-0.00695, -0.04952, 0.00680);
    samples[17] = vec3(0.03549, 0.03524, 0.00370);
    samples[18] = vec3(-0.03515, -0.03572, 0.00380);
    samples[19] = vec3(0.04912, 0.00943, 0.00190);
    samples[20] = vec3(-0.01967, 0.04594, 0.00200);
    samples[21] = vec3(-0.04877, -0.00989, 0.00190);
    samples[22] = vec3(0.01703, -0.04700, 0.00200);
    samples[23] = vec3(-0.00384, 0.04985, 0.00100);
    samples[24] = vec3(-0.04985, 0.00386, 0.00100);
    samples[25] = vec3(0.04985, 0.00386, 0.00100);
    samples[26] = vec3(-0.00384, -0.04985, 0.00100);
    samples[27] = vec3(0.04985, -0.00386, 0.00100);
    samples[28] = vec3(-0.04985, -0.00386, 0.00100);
    samples[29] = vec3(0.00384, 0.04985, 0.00100);
    samples[30] = vec3(0.00384, -0.04985, 0.00100);
    samples[31] = vec3(-0.01967, -0.04594, 0.00200);
    samples[32] = vec3(0.01967, 0.04594, 0.00200);
    samples[33] = vec3(-0.01967, 0.04594, 0.00200);
    samples[34] = vec3(0.01967, -0.04594, 0.00200);
    samples[35] = vec3(-0.03515, 0.03572, 0.00380);
    samples[36] = vec3(0.03515, -0.03572, 0.00380);
    samples[37] = vec3(-0.03515, -0.03572, 0.00380);
    samples[38] = vec3(0.03515, 0.03572, 0.00380);
    samples[39] = vec3(-0.04877, 0.00989, 0.00190);
    samples[40] = vec3(0.04877, -0.00989, 0.00190);
    samples[41] = vec3(-0.04877, -0.00989, 0.00190);
    samples[42] = vec3(0.04877, 0.00989, 0.00190);
    samples[43] = vec3(-0.01703, 0.04700, 0.00200);
    samples[44] = vec3(0.01703, -0.04700, 0.00200);
    samples[45] = vec3(-0.01703, -0.04700, 0.00200);
    samples[46] = vec3(0.01703, 0.04700, 0.00200);
    samples[47] = vec3(-0.04912, -0.00943, 0.00190);
    samples[48] = vec3(0.04912, 0.00943, 0.00190);
    samples[49] = vec3(-0.04912, 0.00943, 0.00190);
    samples[50] = vec3(0.04912, -0.00943, 0.00190);
    samples[51] = vec3(-0.02500, -0.04335, 0.00840);
    samples[52] = vec3(0.02500, 0.04335, 0.00840);
    samples[53] = vec3(-0.02500, 0.04335, 0.00840);
    samples[54] = vec3(0.02500, -0.04335, 0.00840);
    samples[55] = vec3(-0.04987, 0.01095, 0.00620);
    samples[56] = vec3(0.04987, -0.01095, 0.00620);
    samples[57] = vec3(-0.04987, -0.01095, 0.00620);
    samples[58] = vec3(0.04987, 0.01095, 0.00620);
    samples[59] = vec3(-0.03549, -0.03524, 0.00370);
    samples[60] = vec3(0.03549, 0.03524, 0.00370);
    samples[61] = vec3(-0.03549, 0.03524, 0.00370);
    samples[62] = vec3(0.03549, -0.03524, 0.00370);
    samples[63] = vec3(-0.04618, -0.01987, 0.00560);
    return samples[i];
}

void main() {
    float depth = texture(u_depth, v_uv).r;
    if (depth >= 1.0) {
        out_ao = 1.0;
        return;
    }

    vec3 viewPos = getViewPos(v_uv, depth);
    vec3 normal = normalize(cross(dFdx(viewPos), dFdy(viewPos)));

    vec3 randomVec = texture(u_noise, v_uv * ssao.u_noise_scale).xyz * 2.0 - 1.0;
    vec3 tangent = normalize(randomVec - normal * dot(randomVec, normal));
    vec3 bitangent = cross(normal, tangent);
    mat3 TBN = mat3(tangent, bitangent, normal);

    float occlusion = 0.0;
    int kernelSize = int(min(ssao.u_kernel_size, 64u));

    for (int i = 0; i < kernelSize; ++i) {
        vec3 sampleVec = TBN * sampleKernel(i);
        vec3 samplePos = viewPos + sampleVec * ssao.u_radius;

        vec4 offset = ssao.u_projection * vec4(samplePos, 1.0);
        offset.xyz /= offset.w;
        offset.xyz = offset.xyz * 0.5 + 0.5;

        float sampleDepth = texture(u_depth, offset.xy).r;
        vec3 sampleViewPos = getViewPos(offset.xy, sampleDepth);

        float rangeCheck = smoothstep(0.0, 1.0, ssao.u_radius / abs(viewPos.z - sampleViewPos.z));
        occlusion += (sampleViewPos.z >= samplePos.z + ssao.u_bias ? 1.0 : 0.0) * rangeCheck;
    }

    float ao = 1.0 - (occlusion / float(kernelSize));
    ao = pow(ao, ssao.u_power);
    out_ao = mix(1.0, ao, ssao.u_intensity);
}
