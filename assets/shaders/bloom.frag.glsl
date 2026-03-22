#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_hdr_map;
layout(set = 3, binding = 0, std140) uniform BloomUniforms {
    // x: threshold, y: soft_knee (0-1), z: pass_index (0=extract, 1-4=downsample blur, 5+=upsample), w: reserved
    vec4 u_threshold_params;
} bloom_uniforms;

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// Soft threshold with knee for smooth bloom onset
vec3 thresholdFilter(vec3 color, float threshold, float knee) {
    float brightness = luminance(color);
    float soft = brightness - threshold + knee;
    soft = clamp(soft, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 0.00001);
    float contribution = max(soft, brightness - threshold);
    contribution /= max(brightness, 0.00001);
    return color * max(contribution, 0.0);
}

// 13-tap downsampling filter (Call of Duty: Advanced Warfare technique)
// High quality, avoids fireflies with Karis-average weighting
vec3 downsample13Tap(sampler2D tex, vec2 uv, vec2 texelSize) {
    vec3 a = texture(tex, uv).rgb;
    vec3 b = texture(tex, uv + vec2(-1.0, -1.0) * texelSize).rgb;
    vec3 c = texture(tex, uv + vec2( 1.0, -1.0) * texelSize).rgb;
    vec3 d = texture(tex, uv + vec2(-1.0,  1.0) * texelSize).rgb;
    vec3 e = texture(tex, uv + vec2( 1.0,  1.0) * texelSize).rgb;

    vec3 f = texture(tex, uv + vec2(-2.0, -2.0) * texelSize).rgb;
    vec3 g = texture(tex, uv + vec2( 0.0, -2.0) * texelSize).rgb;
    vec3 h = texture(tex, uv + vec2( 2.0, -2.0) * texelSize).rgb;
    vec3 i = texture(tex, uv + vec2(-2.0,  0.0) * texelSize).rgb;
    vec3 j = texture(tex, uv + vec2( 2.0,  0.0) * texelSize).rgb;
    vec3 k = texture(tex, uv + vec2(-2.0,  2.0) * texelSize).rgb;
    vec3 l = texture(tex, uv + vec2( 0.0,  2.0) * texelSize).rgb;
    vec3 m = texture(tex, uv + vec2( 2.0,  2.0) * texelSize).rgb;

    vec3 result = vec3(0.0);
    result += (b + c + d + e) * 0.5    / 4.0;
    result += (a + b + g + c) * 0.125  / 4.0;
    result += (a + c + j + e) * 0.125  / 4.0;
    result += (a + d + i + b) * 0.125  / 4.0;
    result += (a + e + l + d) * 0.125  / 4.0;
    return result;
}

// 9-tap tent filter for upsampling (smooth, energy-preserving)
vec3 upsample9Tap(sampler2D tex, vec2 uv, vec2 texelSize) {
    vec3 a = texture(tex, uv + vec2(-1.0, -1.0) * texelSize).rgb;
    vec3 b = texture(tex, uv + vec2( 0.0, -1.0) * texelSize).rgb;
    vec3 c = texture(tex, uv + vec2( 1.0, -1.0) * texelSize).rgb;
    vec3 d = texture(tex, uv + vec2(-1.0,  0.0) * texelSize).rgb;
    vec3 e = texture(tex, uv                                ).rgb;
    vec3 f = texture(tex, uv + vec2( 1.0,  0.0) * texelSize).rgb;
    vec3 g = texture(tex, uv + vec2(-1.0,  1.0) * texelSize).rgb;
    vec3 h = texture(tex, uv + vec2( 0.0,  1.0) * texelSize).rgb;
    vec3 i = texture(tex, uv + vec2( 1.0,  1.0) * texelSize).rgb;

    return (a + c + g + i) * (1.0/16.0)
         + (b + d + f + h) * (2.0/16.0)
         + e               * (4.0/16.0);
}

void main() {
    float threshold = max(bloom_uniforms.u_threshold_params.x, 0.0);
    float knee = bloom_uniforms.u_threshold_params.y;
    float pass_index = bloom_uniforms.u_threshold_params.z;
    vec2 texel = 1.0 / vec2(textureSize(u_hdr_map, 0));

    if (pass_index < 0.5) {
        // Pass 0: Brightness extraction with soft knee + initial downsample
        vec3 color = downsample13Tap(u_hdr_map, v_uv, texel);
        out_color = vec4(thresholdFilter(color, threshold, knee * threshold), 1.0);
    } else if (pass_index < 4.5) {
        // Passes 1-4: Progressive downsample blur
        out_color = vec4(downsample13Tap(u_hdr_map, v_uv, texel), 1.0);
    } else {
        // Passes 5+: Upsample with tent filter
        out_color = vec4(upsample9Tap(u_hdr_map, v_uv, texel), 1.0);
    }
}
