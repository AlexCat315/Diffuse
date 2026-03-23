#version 450

// Irradiance convolution compute shader — convolves an equirectangular environment map
// into a diffuse irradiance map using hemisphere cosine-weighted sampling.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D u_environment;

layout(set = 1, binding = 0, rgba16f) writeonly uniform image2D u_output;

layout(set = 2, binding = 0) uniform IrradianceParams {
    uint output_size;
    uint sample_count;
    vec2 padding;
} params;

const float PI = 3.141592653589793;

vec3 uvToDirection(vec2 uv) {
    float phi = uv.x * 2.0 * PI - PI;
    float theta = (1.0 - uv.y) * PI;

    float sinTheta = sin(theta);
    return vec3(sinTheta * cos(phi), cos(theta), sinTheta * sin(phi));
}

vec2 directionToUV(vec3 dir) {
    float phi = atan(dir.z, dir.x);
    float theta = acos(clamp(dir.y, -1.0, 1.0));

    float u = (phi + PI) / (2.0 * PI);
    float v = 1.0 - theta / PI;
    return vec2(u, v);
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(params.output_size) || pixel.y >= int(params.output_size)) return;

    vec2 uv = (vec2(pixel) + 0.5) / float(params.output_size);
    vec3 normal = normalize(uvToDirection(uv));

    // Build TBN from normal
    vec3 up = abs(normal.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
    vec3 right = normalize(cross(up, normal));
    up = cross(normal, right);

    vec3 irradiance = vec3(0.0);
    uint samples = params.sample_count;
    float inv_samples = 1.0 / float(samples);

    // Uniform hemisphere sampling with cosine weighting
    for (uint i = 0u; i < samples; ++i) {
        // Stratified sampling using golden ratio
        float fi = float(i) + 0.5;
        float phi = 2.0 * PI * fract(fi * 0.6180339887);
        float cosTheta = 1.0 - fi * inv_samples;
        float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

        // Tangent-space direction
        vec3 tangentSample = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);

        // Transform to world space
        vec3 sampleDir = tangentSample.x * right + tangentSample.y * up + tangentSample.z * normal;

        // Sample environment map
        vec2 sampleUV = directionToUV(sampleDir);
        vec3 color = texture(u_environment, sampleUV).rgb;

        // Cosine-weighted contribution
        float NdotL = max(dot(normal, sampleDir), 0.0);
        irradiance += color * NdotL;
    }

    irradiance = irradiance * PI * inv_samples;

    imageStore(u_output, pixel, vec4(irradiance, 1.0));
}
