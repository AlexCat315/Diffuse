#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_fog;

layout(set = 2, binding = 0) uniform sampler2D u_depth;
layout(set = 2, binding = 1) uniform sampler2DShadow u_shadow_map;

layout(set = 3, binding = 0, std140) uniform VolumetricFogUniforms {
    mat4 u_inv_view_projection;
    mat4 u_light_space_matrix;
    vec4 u_camera_position;        // xyz: camera pos, w: unused
    vec4 u_light_direction;        // xyz: dir (toward light), w: unused
    vec4 u_light_color;            // xyz: color, w: intensity
    vec4 u_fog_params;             // x: density, y: height_falloff, z: max_distance, w: num_steps
    vec4 u_fog_color;              // xyz: scattering color, w: absorption
    vec4 u_noise_params;           // x: wind_time, y: noise_scale, z: noise_strength, w: unused
} fog;

const float PI = 3.14159265359;

// Henyey-Greenstein phase function for realistic light scattering
float phaseHG(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return (1.0 - g2) / (4.0 * PI * denom * sqrt(denom));
}

// Dual-lobe phase function: combine forward and back scatter
float phaseDual(float cosTheta) {
    return 0.7 * phaseHG(cosTheta, 0.6) + 0.3 * phaseHG(cosTheta, -0.3);
}

// Simple 3D hash for procedural noise (no texture required)
float hash3D(vec3 p) {
    p = fract(p * vec3(443.897, 441.423, 437.195));
    p += dot(p, p.yzx + 19.19);
    return fract((p.x + p.y) * p.z);
}

// Value noise with trilinear interpolation
float valueNoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f); // smoothstep

    float a = hash3D(i);
    float b = hash3D(i + vec3(1.0, 0.0, 0.0));
    float c = hash3D(i + vec3(0.0, 1.0, 0.0));
    float d = hash3D(i + vec3(1.0, 1.0, 0.0));
    float e = hash3D(i + vec3(0.0, 0.0, 1.0));
    float f2 = hash3D(i + vec3(1.0, 0.0, 1.0));
    float g = hash3D(i + vec3(0.0, 1.0, 1.0));
    float h = hash3D(i + vec3(1.0, 1.0, 1.0));

    return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y),
               mix(mix(e, f2, f.x), mix(g, h, f.x), f.y), f.z);
}

// FBM (fractal Brownian motion) for cloud-like density
float fbmNoise(vec3 p) {
    float v = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 3; ++i) {
        v += amplitude * valueNoise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return v;
}

vec3 worldPosFromDepth(vec2 uv, float depth) {
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 worldPos = fog.u_inv_view_projection * clipPos;
    return worldPos.xyz / worldPos.w;
}

// Check if a point is in shadow
float sampleShadow(vec3 worldPos) {
    vec4 lightSpace = fog.u_light_space_matrix * vec4(worldPos, 1.0);
    vec3 proj = lightSpace.xyz / lightSpace.w;
    proj = proj * 0.5 + 0.5;
    if (proj.x < 0.0 || proj.x > 1.0 || proj.y < 0.0 || proj.y > 1.0 || proj.z > 1.0) {
        return 1.0;
    }
    return texture(u_shadow_map, vec3(proj.xy, proj.z - 0.002));
}

void main() {
    float depth = texture(u_depth, v_uv).r;
    if (depth >= 1.0) {
        // Sky: apply basic atmospheric scattering only
        out_fog = vec4(0.0);
        return;
    }

    vec3 worldPos = worldPosFromDepth(v_uv, depth);
    vec3 rayOrigin = fog.u_camera_position.xyz;
    vec3 rayDir = normalize(worldPos - rayOrigin);
    float rayLength = min(length(worldPos - rayOrigin), fog.u_fog_params.z);

    int numSteps = int(fog.u_fog_params.w);
    numSteps = clamp(numSteps, 8, 64);
    float stepSize = rayLength / float(numSteps);

    // Phase function: angle between view ray and light direction
    float cosTheta = dot(rayDir, normalize(-fog.u_light_direction.xyz));
    float phase = phaseDual(cosTheta);

    float density = fog.u_fog_params.x;
    float heightFalloff = fog.u_fog_params.y;
    float absorption = fog.u_fog_color.w;

    vec3 lightColor = fog.u_light_color.rgb * fog.u_light_color.w;
    vec3 fogScatterColor = fog.u_fog_color.rgb;

    vec3 inScatter = vec3(0.0);
    float transmittance = 1.0;

    // Dithered ray start to reduce banding
    float dither = hash3D(vec3(v_uv * fog.u_noise_params.y, fog.u_noise_params.x)) * stepSize;

    for (int i = 0; i < numSteps; ++i) {
        float t = (float(i) + 0.5) * stepSize + dither;
        vec3 samplePos = rayOrigin + rayDir * t;

        // Height-based exponential density falloff
        float h = max(samplePos.y, 0.0);
        float localDensity = density * exp(-h * heightFalloff);

        // Procedural noise for non-uniform fog
        float noiseStrength = fog.u_noise_params.z;
        if (noiseStrength > 0.001) {
            float noiseScale = fog.u_noise_params.y;
            vec3 noiseCoord = samplePos * noiseScale + vec3(fog.u_noise_params.x * 0.3, 0.0, fog.u_noise_params.x * 0.1);
            float noise = fbmNoise(noiseCoord);
            localDensity *= mix(1.0, noise * 2.0, noiseStrength);
        }

        localDensity = max(localDensity, 0.0);

        // Beer's law extinction
        float extinction = localDensity * stepSize * absorption;
        float stepTransmittance = exp(-extinction);

        // Volumetric shadow: check if this point receives light
        float shadowValue = sampleShadow(samplePos);

        // In-scattering: light contribution at this point
        vec3 stepScatter = fogScatterColor * lightColor * phase * shadowValue * localDensity * stepSize;

        // Energy-conserving integration (Frostbite 2014 technique)
        inScatter += stepScatter * transmittance;
        transmittance *= stepTransmittance;

        // Early exit when fog is fully opaque
        if (transmittance < 0.01) break;
    }

    // Output: rgb = in-scattered light, a = transmittance
    out_fog = vec4(inScatter, transmittance);
}
