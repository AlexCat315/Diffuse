#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_hdr_map;
layout(set = 2, binding = 1) uniform sampler2D u_bloom_map;
layout(set = 2, binding = 2) uniform sampler2D u_lut_map;
layout(set = 3, binding = 0, std140) uniform TonemapUniforms {
    // x: 启用手动曝光, y: 曝光倍率, z: 启用自动曝光, w: 自动曝光适应速度
    vec4 u_exposure_params;
    // x: 启用 Bloom, y: Bloom 强度
    vec4 u_bloom_params;
    // x: 启用 Color Grading, y: 饱和度, z: 对比度, w: Gamma
    vec4 u_color_grading_params;
    // x: 启用 LUT, y: LUT 强度, z: 启用 sRGB gamma, w: reserved
    vec4 u_lut_params;
} tonemap_uniforms;

const float LUT_SIZE = 16.0;

// --- Tonemapping operators ---

// Fitted ACES (Narkowicz 2015)
vec3 ACESFilm(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// --- sRGB transfer function (IEC 61966-2-1) ---
vec3 linearToSRGB(vec3 linear) {
    vec3 lo = linear * 12.92;
    vec3 hi = 1.055 * pow(max(linear, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
    return mix(lo, hi, step(vec3(0.0031308), linear));
}

// --- Auto-exposure: compute scene log-average luminance from downsampled HDR ---
float computeAutoExposure(sampler2D hdr) {
    float log_sum = 0.0;
    float count = 0.0;
    // Sample a 4x4 grid from the center 80% of the screen
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            vec2 sample_uv = vec2(0.1 + 0.8 * (float(x) + 0.5) / 4.0,
                                  0.1 + 0.8 * (float(y) + 0.5) / 4.0);
            vec3 c = textureLod(hdr, sample_uv, 6.0).rgb; // sample from high mip
            float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
            log_sum += log(max(luma, 0.0001));
            count += 1.0;
        }
    }
    float avg_luma = exp(log_sum / count);
    // Key value mapping: target 18% grey (Reinhard-style)
    float key = 0.18;
    return key / max(avg_luma, 0.001);
}

vec3 applyColorGrading(vec3 color) {
    float saturation = max(tonemap_uniforms.u_color_grading_params.y, 0.0);
    float contrast = max(tonemap_uniforms.u_color_grading_params.z, 0.0);
    float gamma = max(tonemap_uniforms.u_color_grading_params.w, 0.001);

    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, saturation);
    color = (color - 0.5) * contrast + 0.5;
    color = pow(max(color, vec3(0.0)), vec3(1.0 / gamma));
    return clamp(color, 0.0, 1.0);
}

vec3 sampleColorLUT(vec3 color) {
    color = clamp(color, 0.0, 1.0);

    float blue = color.b * (LUT_SIZE - 1.0);
    float blue0 = floor(blue);
    float blue1 = min(blue0 + 1.0, LUT_SIZE - 1.0);
    float red = color.r * (LUT_SIZE - 1.0);
    float green = color.g * (LUT_SIZE - 1.0);

    vec2 uv0 = vec2(
        (blue0 * LUT_SIZE + red + 0.5) / (LUT_SIZE * LUT_SIZE),
        (green + 0.5) / LUT_SIZE
    );
    vec2 uv1 = vec2(
        (blue1 * LUT_SIZE + red + 0.5) / (LUT_SIZE * LUT_SIZE),
        (green + 0.5) / LUT_SIZE
    );

    vec3 graded0 = texture(u_lut_map, uv0).rgb;
    vec3 graded1 = texture(u_lut_map, uv1).rgb;
    return mix(graded0, graded1, fract(blue));
}

void main() {
    vec3 hdr_color = texture(u_hdr_map, v_uv).rgb;

    // Bloom compositing
    if (tonemap_uniforms.u_bloom_params.x > 0.5) {
        hdr_color += texture(u_bloom_map, v_uv).rgb * max(tonemap_uniforms.u_bloom_params.y, 0.0);
    }

    // Exposure: manual or auto
    float exposure = 1.0;
    if (tonemap_uniforms.u_exposure_params.z > 0.5) {
        // Auto-exposure from scene luminance
        exposure = clamp(computeAutoExposure(u_hdr_map), 0.02, 50.0);
    } else if (tonemap_uniforms.u_exposure_params.x > 0.5) {
        exposure = max(tonemap_uniforms.u_exposure_params.y, 0.0);
    }
    hdr_color *= exposure;

    // ACES tonemapping (linear HDR -> linear LDR)
    vec3 ldr_color = ACESFilm(hdr_color);

    // Color grading in linear space
    if (tonemap_uniforms.u_color_grading_params.x > 0.5) {
        ldr_color = applyColorGrading(ldr_color);
    }

    // LUT application
    if (tonemap_uniforms.u_lut_params.x > 0.5) {
        vec3 lut_color = sampleColorLUT(ldr_color);
        ldr_color = mix(ldr_color, lut_color, clamp(tonemap_uniforms.u_lut_params.y, 0.0, 1.0));
    }

    // sRGB gamma curve (proper IEC 61966-2-1 transfer)
    // Required when output target is bgra8_unorm (not _srgb)
    if (tonemap_uniforms.u_lut_params.z > 0.5) {
        ldr_color = linearToSRGB(ldr_color);
    }

    out_color = vec4(ldr_color, 1.0);
}
