#import <Metal/Metal.h>
#include <cstring>
#include <cstdio>
#include "metal_rt_bridge.h"

// ---------------------------------------------------------------------------
// Metal Shading Language — 路径追踪 compute kernel (Metal RT)
// ---------------------------------------------------------------------------
static const char* kMetalRTShaderSource = R"METAL(
#include <metal_stdlib>
#include <metal_raytracing>

using namespace metal;
using namespace raytracing;

struct RTTriangle {
    packed_float3 v0, v1, v2;
    packed_float3 n0, n1, n2;
    packed_float2 uv0, uv1, uv2;
    packed_float3 albedo;
    packed_float3 emissive;
    float metallic;
    float roughness;
    float transmission;
    float ior;
    float thickness;
    int base_color_texture_index;
    int metallic_roughness_texture_index;
    int normal_texture_index;
    int occlusion_texture_index;
    int emissive_texture_index;
};

struct RTTextureMeta {
    uint offset;  // byte offset in packed BGRA8 pixel buffer
    uint width;
    uint height;
    uint format;
};

struct RTSamplingTableMeta {
    uint offset;    // byte offset in packed sampling-table buffer
    uint byte_size; // size of this table in bytes
    uint kind;      // 0 = environment importance, 1 = emissive light
    uint _pad;
};

struct RTParams {
    float4x4 inv_view_projection;
    packed_float3 camera_origin;
    float _pad0;
    packed_float3 light_direction;
    float sun_angular_radius;       // 太阳角半径（弧度），控制软阴影半影宽度
    uint2 dimensions;
    uint samples;
    uint bounces;
    uint mode;       // 0 = path trace, 1 = shadow only
    uint shadow_samples; // shadow-only 每像素采样数 (1=硬阴影, 4+=软阴影)
    uint output_is_half;
    int environment_texture_index;
    packed_float4 exposure_params;
    packed_float4 color_grading_params;
    uint directional_light_count;
    uint point_light_count;
    uint spot_light_count;
    uint sampling_table_count;
    packed_float3 directional_light_directions[4];
    packed_float3 directional_light_radiance[4];
    packed_float3 point_light_positions[16];
    packed_float3 point_light_radiance[16];
    float point_light_ranges[16];
    packed_float3 spot_light_positions[16];
    packed_float3 spot_light_directions[16];
    packed_float3 spot_light_radiance[16];
    float spot_light_ranges[16];
    float spot_light_inner_angle_cos[16];
    float spot_light_outer_angle_cos[16];
    uint environment_importance_width;
    uint environment_importance_height;
    float emissive_total_area;
    uint _tail_pad;
};

// ---- deterministic hash RNG (与 CPU 路径追踪保持一致) ----
static uint hash_u32(uint x) {
    x ^= x >> 17;
    x *= 0xed5ad4bbu;
    x ^= x >> 11;
    x *= 0xac4c1b51u;
    x ^= x >> 15;
    x *= 0x31848babu;
    x ^= x >> 14;
    return x;
}

static float hash_unit_float(uint seed) {
    return float(hash_u32(seed) & 0x00FFFFFFu) / 16777215.0f;
}

static float3 random_hemisphere(float3 normal, uint seed) {
    float3 jitter = normalize(float3(
        hash_unit_float(seed ^ 0x68bc21ebu) * 2.0f - 1.0f,
        hash_unit_float(seed ^ 0x02e5be93u) * 2.0f - 1.0f,
        hash_unit_float(seed ^ 0xa3d95fa1u) * 2.0f - 1.0f
    ));
    return normalize(normal + jitter);
}

// 在光方向周围的锥体内随机采样方向 (用于软阴影)
static float3 sample_cone(float3 dir, float cone_angle, uint seed) {
    if (cone_angle < 1e-6f) return dir;
    // 构建切线空间
    float3 up = (abs(dir.y) < 0.999f) ? float3(0,1,0) : float3(1,0,0);
    float3 T = normalize(cross(up, dir));
    float3 B = cross(dir, T);
    // 均匀分布采样锥体
    float u1 = hash_unit_float(seed ^ 0x3c84ef95u);
    float u2 = hash_unit_float(seed ^ 0x7e6b2f31u);
    float cos_max = cos(cone_angle);
    float cos_theta = 1.0f - u1 * (1.0f - cos_max);
    float sin_theta = sqrt(max(0.0f, 1.0f - cos_theta * cos_theta));
    float phi = 2.0f * 3.14159265f * u2;
    return normalize(sin_theta * cos(phi) * T + sin_theta * sin(phi) * B + cos_theta * dir);
}

static float3 reflect_vec(float3 incident, float3 normal) {
    return incident - 2.0f * dot(incident, normal) * normal;
}

static bool refract_vec(float3 incident, float3 normal, float eta, thread float3& out_dir) {
    float cos_i = clamp(-dot(normal, incident), -1.0f, 1.0f);
    float k = 1.0f - eta * eta * (1.0f - cos_i * cos_i);
    if (k < 0.0f) return false;
    out_dir = eta * incident + (eta * cos_i - sqrt(k)) * normal;
    return true;
}

constant uint TEXFMT_BGRA8_UNORM = 3u;
constant uint TEXFMT_BGRA8_UNORM_SRGB = 4u;
constant uint TEXFMT_RGBA8_UNORM_SRGB = 5u;
constant uint TEXFMT_RGBA16_FLOAT = 6u;
constant uint TEXFMT_RGBA32_FLOAT = 7u;

static float3 read_texel_texture_atlas(
    device const uchar* atlas,
    constant RTTextureMeta& tm,
    uint tx,
    uint ty
) {
    uint index = ty * tm.width + tx;
    uint base = tm.offset;
    if (tm.format == TEXFMT_RGBA32_FLOAT) {
        device const float* f32 = reinterpret_cast<device const float*>(atlas + base + index * 16u);
        return float3(f32[0], f32[1], f32[2]);
    }
    if (tm.format == TEXFMT_RGBA16_FLOAT) {
        device const half* f16 = reinterpret_cast<device const half*>(atlas + base + index * 8u);
        return float3(float(f16[0]), float(f16[1]), float(f16[2]));
    }
    const uint px_off = base + index * 4u;
    float byte0 = float(atlas[px_off + 0]) / 255.0f;
    float byte1 = float(atlas[px_off + 1]) / 255.0f;
    float byte2 = float(atlas[px_off + 2]) / 255.0f;
    if (tm.format == TEXFMT_BGRA8_UNORM || tm.format == TEXFMT_BGRA8_UNORM_SRGB) {
        // BGRA: byte0=B, byte1=G, byte2=R
        return float3(pow(byte2, 2.2f), pow(byte1, 2.2f), pow(byte0, 2.2f));
    }
    // RGBA: byte0=R, byte1=G, byte2=B
    return float3(pow(byte0, 2.2f), pow(byte1, 2.2f), pow(byte2, 2.2f));
}

static float4 read_texel_texture_atlas_raw(
    device const uchar* atlas,
    constant RTTextureMeta& tm,
    uint tx,
    uint ty
) {
    uint index = ty * tm.width + tx;
    uint base = tm.offset;
    if (tm.format == TEXFMT_RGBA32_FLOAT) {
        device const float* f32 = reinterpret_cast<device const float*>(atlas + base + index * 16u);
        return float4(f32[0], f32[1], f32[2], f32[3]);
    }
    if (tm.format == TEXFMT_RGBA16_FLOAT) {
        device const half* f16 = reinterpret_cast<device const half*>(atlas + base + index * 8u);
        return float4(float(f16[0]), float(f16[1]), float(f16[2]), float(f16[3]));
    }
    const uint px_off = base + index * 4u;
    float byte0 = float(atlas[px_off + 0]) / 255.0f;
    float byte1 = float(atlas[px_off + 1]) / 255.0f;
    float byte2 = float(atlas[px_off + 2]) / 255.0f;
    float byte3 = float(atlas[px_off + 3]) / 255.0f;
    if (tm.format == TEXFMT_BGRA8_UNORM || tm.format == TEXFMT_BGRA8_UNORM_SRGB) {
        return float4(byte2, byte1, byte0, byte3);
    }
    return float4(byte0, byte1, byte2, byte3);
}

// 从打包纹理图集中双线性采样 (BGRA8)
static float3 sample_texture_atlas(
    device const uchar* atlas,
    constant RTTextureMeta* meta,
    int tex_index,
    float u_in, float v_in
) {
    constant RTTextureMeta& tm = meta[tex_index];
    uint tw = tm.width;
    uint th = tm.height;

    // wrap UV to [0,1)
    float u = u_in - floor(u_in);
    float v = v_in - floor(v_in);
    if (u < 0.0f) u += 1.0f;
    if (v < 0.0f) v += 1.0f;

    float fx = u * float(tw) - 0.5f;
    float fy = v * float(th) - 0.5f;
    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    float frac_x = fx - floor(fx);
    float frac_y = fy - floor(fy);

    int iw = int(tw);
    int ih = int(th);
    uint x0u = uint(((x0 % iw) + iw) % iw);
    uint y0u = uint(((y0 % ih) + ih) % ih);
    uint x1u = uint((((x0 + 1) % iw) + iw) % iw);
    uint y1u = uint((((y0 + 1) % ih) + ih) % ih);

    float3 c00 = read_texel_texture_atlas(atlas, tm, x0u, y0u);
    float3 c10 = read_texel_texture_atlas(atlas, tm, x1u, y0u);
    float3 c01 = read_texel_texture_atlas(atlas, tm, x0u, y1u);
    float3 c11 = read_texel_texture_atlas(atlas, tm, x1u, y1u);

    return mix(mix(c00, c10, frac_x), mix(c01, c11, frac_x), frac_y);
}

static float4 sample_texture_atlas_raw(
    device const uchar* atlas,
    constant RTTextureMeta* meta,
    int tex_index,
    float u_in, float v_in
) {
    constant RTTextureMeta& tm = meta[tex_index];
    uint tw = tm.width;
    uint th = tm.height;

    float u = u_in - floor(u_in);
    float v = v_in - floor(v_in);
    if (u < 0.0f) u += 1.0f;
    if (v < 0.0f) v += 1.0f;

    float fx = u * float(tw) - 0.5f;
    float fy = v * float(th) - 0.5f;
    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    float frac_x = fx - floor(fx);
    float frac_y = fy - floor(fy);

    int iw = int(tw);
    int ih = int(th);
    uint x0u = uint(((x0 % iw) + iw) % iw);
    uint y0u = uint(((y0 % ih) + ih) % ih);
    uint x1u = uint((((x0 + 1) % iw) + iw) % iw);
    uint y1u = uint((((y0 + 1) % ih) + ih) % ih);

    float4 c00 = read_texel_texture_atlas_raw(atlas, tm, x0u, y0u);
    float4 c10 = read_texel_texture_atlas_raw(atlas, tm, x1u, y0u);
    float4 c01 = read_texel_texture_atlas_raw(atlas, tm, x0u, y1u);
    float4 c11 = read_texel_texture_atlas_raw(atlas, tm, x1u, y1u);

    return mix(mix(c00, c10, frac_x), mix(c01, c11, frac_x), frac_y);
}

static float3 sample_environment(
    device const uchar* atlas,
    constant RTTextureMeta* meta,
    int env_tex_index,
    float3 dir
) {
    if (env_tex_index >= 0) {
        float3 nd = normalize(dir);
        float u = atan2(nd.z, nd.x) / (2.0f * 3.14159265f) + 0.5f;
        float v = 0.5f - asin(clamp(nd.y, -1.0f, 1.0f)) / 3.14159265f;
        return sample_texture_atlas(atlas, meta, env_tex_index, u, v);
    }
    return float3(0.0f);
}

constant uint RT_SAMPLING_TABLE_ENVIRONMENT_IMPORTANCE = 0u;
constant uint RT_SAMPLING_TABLE_EMISSIVE_LIGHT = 1u;

struct PathTraceEnvImportance {
    float q;
    float pmf;
    uint alias;
};

struct PathTraceEmissiveLight {
    uint triangle_index;
    float cdf;
};

struct PathTraceBsdfEval {
    float3 value;
    float pdf;
};

struct PathTraceLobeProbabilities {
    float diffuse;
    float specular;
};

struct PathTraceDirectLightSample {
    float3 direction;
    float3 radiance;
    float pdf;
    float distance;
    uint valid;
    uint delta;
};

static float sqr(float value) {
    return value * value;
}

static float luminance(float3 rgb) {
    return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

static float max_component(float3 rgb) {
    return max(rgb.x, max(rgb.y, rgb.z));
}

static float3 one_minus(float3 value) {
    return float3(1.0f) - value;
}

static float3 safe_normalize(float3 value, float3 fallback) {
    float len2 = dot(value, value);
    if (len2 <= 1e-12f) return fallback;
    return value * rsqrt(len2);
}

static float power_heuristic(float pdf_a, float pdf_b) {
    float a2 = pdf_a * pdf_a;
    float b2 = pdf_b * pdf_b;
    float denom = a2 + b2;
    if (denom <= 0.0f) return 0.0f;
    return a2 / denom;
}

static float2 direction_to_environment_uv(float3 direction) {
    float3 dir = safe_normalize(direction, float3(0.0f, 1.0f, 0.0f));
    return float2(
        atan2(dir.z, dir.x) / (2.0f * 3.14159265f) + 0.5f,
        0.5f - asin(clamp(dir.y, -1.0f, 1.0f)) / 3.14159265f
    );
}

static float3 environment_uv_to_direction(float u, float v) {
    float phi = (u - 0.5f) * (2.0f * 3.14159265f);
    float theta = clamp(v, 0.0f, 1.0f) * 3.14159265f;
    float sin_theta = sin(theta);
    return safe_normalize(
        float3(cos(phi) * sin_theta, cos(theta), sin(phi) * sin_theta),
        float3(0.0f, 1.0f, 0.0f)
    );
}

static float3 frame_to_world(float3 normal, float3 local_dir) {
    float3 up = (abs(normal.y) < 0.999f) ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 tangent = safe_normalize(cross(up, normal), float3(1.0f, 0.0f, 0.0f));
    float3 bitangent = cross(normal, tangent);
    return safe_normalize(tangent * local_dir.x + bitangent * local_dir.y + normal * local_dir.z, normal);
}

static float3 world_to_frame(float3 normal, float3 world_dir) {
    float3 up = (abs(normal.y) < 0.999f) ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 tangent = safe_normalize(cross(up, normal), float3(1.0f, 0.0f, 0.0f));
    float3 bitangent = cross(normal, tangent);
    return float3(dot(world_dir, tangent), dot(world_dir, bitangent), dot(world_dir, normal));
}

static float3 sample_cosine_hemisphere(float3 normal, uint seed) {
    float rand_u = hash_unit_float(seed ^ 0x68bc21ebu);
    float rand_v = hash_unit_float(seed ^ 0x02e5be93u);
    float r = sqrt(rand_u);
    float phi = 2.0f * 3.14159265f * rand_v;
    float3 local_dir = float3(
        r * cos(phi),
        r * sin(phi),
        sqrt(max(0.0f, 1.0f - rand_u))
    );
    return frame_to_world(normal, local_dir);
}

static float3 sample_ggx_visible_half_vector(float3 normal, float3 view_dir, float roughness, uint seed) {
    float3 local_view = world_to_frame(normal, view_dir);
    if (local_view.z <= 0.0f) return normal;

    float alpha = max(roughness * roughness, 0.001f);
    float rand_u = hash_unit_float(seed ^ 0xa3d95fa1u);
    float rand_v = hash_unit_float(seed ^ 0x51c8e12du);
    float3 stretched_view = safe_normalize(float3(alpha * local_view.x, alpha * local_view.y, max(local_view.z, 1e-6f)), float3(0.0f, 0.0f, 1.0f));
    float lensq = stretched_view.x * stretched_view.x + stretched_view.y * stretched_view.y;
    float3 tangent_1 = (lensq > 0.0f)
        ? float3(-stretched_view.y, stretched_view.x, 0.0f) * rsqrt(lensq)
        : float3(1.0f, 0.0f, 0.0f);
    float3 tangent_2 = cross(stretched_view, tangent_1);

    float r = sqrt(rand_u);
    float phi = 2.0f * 3.14159265f * rand_v;
    float p1 = r * cos(phi);
    float p2 = r * sin(phi);
    float s = 0.5f * (1.0f + stretched_view.z);
    p2 = (1.0f - s) * sqrt(max(0.0f, 1.0f - p1 * p1)) + s * p2;
    float p3 = sqrt(max(0.0f, 1.0f - p1 * p1 - p2 * p2));
    float3 micro_normal = safe_normalize(tangent_1 * p1 + tangent_2 * p2 + stretched_view * p3, float3(0.0f, 0.0f, 1.0f));
    float3 unstretched = float3(alpha * micro_normal.x, alpha * micro_normal.y, max(micro_normal.z, 0.0f));
    return frame_to_world(normal, unstretched);
}

static float distribution_ggx(float n_dot_h, float roughness) {
    float alpha = max(roughness * roughness, 0.001f);
    float alpha2 = alpha * alpha;
    float n_dot_h2 = n_dot_h * n_dot_h;
    float denom_term = n_dot_h2 * (alpha2 - 1.0f) + 1.0f;
    return alpha2 / max(3.14159265f * denom_term * denom_term, 1e-6f);
}

static float geometry_schlick_ggx(float n_dot_x, float roughness) {
    float r = roughness + 1.0f;
    float k = (r * r) * 0.125f;
    return n_dot_x / max(n_dot_x * (1.0f - k) + k, 1e-6f);
}

static float geometry_smith_ggx(float n_dot_v, float n_dot_l, float roughness) {
    return geometry_schlick_ggx(n_dot_v, roughness) * geometry_schlick_ggx(n_dot_l, roughness);
}

static float smith_masking_g1_ggx(float n_dot_x, float roughness) {
    if (n_dot_x <= 0.0f) return 0.0f;
    if (n_dot_x >= 1.0f) return 1.0f;
    float alpha = max(roughness * roughness, 0.001f);
    float alpha2 = alpha * alpha;
    float sin_theta2 = max(0.0f, 1.0f - n_dot_x * n_dot_x);
    float tan_theta2 = sin_theta2 / max(n_dot_x * n_dot_x, 1e-6f);
    return 2.0f / (1.0f + sqrt(1.0f + alpha2 * tan_theta2));
}

static float3 fresnel_schlick(float cos_theta, float3 f0) {
    float factor = pow(clamp(1.0f - cos_theta, 0.0f, 1.0f), 5.0f);
    return f0 + (1.0f - f0) * factor;
}

static PathTraceLobeProbabilities compute_opaque_lobe_probabilities(
    float3 albedo,
    float metallic,
    float transmission,
    float3 fresnel_view
) {
    float diffuse_weight = max(0.0f, max_component(albedo) * (1.0f - metallic) * (1.0f - transmission) * (1.0f - luminance(fresnel_view)));
    float specular_weight = max(0.0f, luminance(fresnel_view) + metallic * 0.35f + 0.05f);
    float total = diffuse_weight + specular_weight;
    if (total <= 1e-6f) {
        return PathTraceLobeProbabilities{1.0f, 0.0f};
    }
    return PathTraceLobeProbabilities{diffuse_weight / total, specular_weight / total};
}

static float ggx_specular_pdf(float3 normal, float3 view_dir, float3 light_dir, float roughness) {
    float3 half_vector_raw = view_dir + light_dir;
    if (dot(half_vector_raw, half_vector_raw) <= 1e-6f) return 0.0f;
    float3 half_vector = safe_normalize(half_vector_raw, normal);
    float n_dot_v = saturate(dot(normal, view_dir));
    float n_dot_h = saturate(dot(normal, half_vector));
    float v_dot_h = saturate(dot(view_dir, half_vector));
    if (n_dot_v <= 0.0f || n_dot_h <= 0.0f || v_dot_h <= 0.0f) return 0.0f;
    float visible_masking = smith_masking_g1_ggx(n_dot_v, roughness);
    return distribution_ggx(n_dot_h, roughness) * visible_masking / max(4.0f * n_dot_v, 1e-6f);
}

static PathTraceBsdfEval evaluate_opaque_bsdf(
    float3 albedo,
    float metallic,
    float roughness,
    float transmission,
    float3 normal,
    float3 view_dir,
    float3 light_dir
) {
    float n_dot_v = saturate(dot(normal, view_dir));
    float n_dot_l = saturate(dot(normal, light_dir));
    if (n_dot_v <= 0.0f || n_dot_l <= 0.0f) {
        return PathTraceBsdfEval{float3(0.0f), 0.0f};
    }

    float3 half_vector = safe_normalize(view_dir + light_dir, normal);
    float n_dot_h = saturate(dot(normal, half_vector));
    float v_dot_h = saturate(dot(view_dir, half_vector));
    float opaque_weight = 1.0f - transmission;
    float3 dielectric_f0 = float3(0.04f);
    float3 f0 = mix(dielectric_f0, albedo, metallic);
    float3 fresnel = fresnel_schlick(v_dot_h, f0);
    float3 fresnel_view = fresnel_schlick(n_dot_v, f0);
    PathTraceLobeProbabilities probs = compute_opaque_lobe_probabilities(albedo, metallic, transmission, fresnel_view);
    float distribution = distribution_ggx(n_dot_h, roughness);
    float geometry = geometry_smith_ggx(n_dot_v, n_dot_l, roughness);
    float spec_scale = opaque_weight * distribution * geometry / max(4.0f * n_dot_v * n_dot_l, 1e-6f);
    float3 specular = fresnel * spec_scale;
    float3 diffuse_color = albedo * ((1.0f - metallic) * opaque_weight);
    float3 diffuse = diffuse_color * one_minus(fresnel) * (1.0f / 3.14159265f);
    float pdf = probs.diffuse * (n_dot_l / 3.14159265f) +
        probs.specular * ggx_specular_pdf(normal, view_dir, light_dir, roughness);
    return PathTraceBsdfEval{diffuse + specular, pdf};
}

static float3 triangle_geometric_normal(constant RTTriangle& tri) {
    return safe_normalize(cross(float3(tri.v1) - float3(tri.v0), float3(tri.v2) - float3(tri.v0)), float3(0.0f, 1.0f, 0.0f));
}

struct RTTangentFrame {
    float3 tangent;
    float3 bitangent;
    float3 normal;
};

static RTTangentFrame build_tangent_frame(float3 normal) {
    float3 up = (abs(normal.y) < 0.999f) ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 tangent = safe_normalize(cross(up, normal), float3(1.0f, 0.0f, 0.0f));
    return RTTangentFrame{tangent, cross(normal, tangent), normal};
}

static RTTangentFrame build_triangle_tangent_frame(constant RTTriangle& tri, float3 normal) {
    float3 edge1 = float3(tri.v1) - float3(tri.v0);
    float3 edge2 = float3(tri.v2) - float3(tri.v0);
    float2 duv1 = float2(tri.uv1) - float2(tri.uv0);
    float2 duv2 = float2(tri.uv2) - float2(tri.uv0);
    float det = duv1.x * duv2.y - duv1.y * duv2.x;
    if (abs(det) <= 1e-6f) return build_tangent_frame(normal);

    float inv_det = 1.0f / det;
    float3 tangent = float3(
        (edge1.x * duv2.y - edge2.x * duv1.y) * inv_det,
        (edge1.y * duv2.y - edge2.y * duv1.y) * inv_det,
        (edge1.z * duv2.y - edge2.z * duv1.y) * inv_det
    );
    if (dot(tangent, tangent) <= 1e-6f) return build_tangent_frame(normal);
    tangent = safe_normalize(tangent - normal * dot(normal, tangent), float3(1.0f, 0.0f, 0.0f));
    float3 bitangent = cross(normal, tangent);
    float3 bitangent_raw = float3(
        (edge2.x * duv1.x - edge1.x * duv2.x) * inv_det,
        (edge2.y * duv1.x - edge1.y * duv2.x) * inv_det,
        (edge2.z * duv1.x - edge1.z * duv2.x) * inv_det
    );
    if (dot(bitangent, bitangent_raw) < 0.0f) {
        bitangent = -bitangent;
    }
    return RTTangentFrame{tangent, bitangent, normal};
}

static int find_sampling_table(constant RTSamplingTableMeta* meta, uint count, uint kind) {
    for (uint i = 0; i < count; i++) {
        if (meta[i].kind == kind) return int(i);
    }
    return -1;
}

static float environment_direction_pdf(
    device const uchar* sample_data,
    constant RTSamplingTableMeta* sample_meta,
    constant RTParams& params,
    int env_table_index,
    float3 direction
) {
    if (env_table_index < 0 || params.environment_importance_width == 0u || params.environment_importance_height == 0u) return 0.0f;
    constant RTSamplingTableMeta& table = sample_meta[env_table_index];
    device const PathTraceEnvImportance* env_table =
        reinterpret_cast<device const PathTraceEnvImportance*>(sample_data + table.offset);
    float2 uv = direction_to_environment_uv(direction);
    uint x = min(params.environment_importance_width - 1u, uint(uv.x * float(params.environment_importance_width)));
    uint y = min(params.environment_importance_height - 1u, uint(uv.y * float(params.environment_importance_height)));
    uint cell_index = y * params.environment_importance_width + x;
    float pmf = env_table[cell_index].pmf;
    float theta = clamp(uv.y, 0.0f, 1.0f) * 3.14159265f;
    float sin_theta = max(sin(theta), 0.0001f);
    float solid_angle =
        (2.0f * 3.14159265f / float(params.environment_importance_width)) *
        (3.14159265f / float(params.environment_importance_height)) *
        sin_theta;
    return pmf / max(solid_angle, 1e-6f);
}

static PathTraceDirectLightSample make_invalid_direct_light_sample() {
    return PathTraceDirectLightSample{float3(0.0f), float3(0.0f), 0.0f, 0.0f, 0u, 0u};
}

static PathTraceDirectLightSample sample_environment_light(
    device const uchar* tex_atlas,
    constant RTTextureMeta* tex_meta,
    device const uchar* sample_data,
    constant RTSamplingTableMeta* sample_meta,
    constant RTParams& params,
    int env_table_index,
    uint seed
) {
    if (params.environment_texture_index < 0 || env_table_index < 0 ||
        params.environment_importance_width == 0u || params.environment_importance_height == 0u) {
        return make_invalid_direct_light_sample();
    }
    constant RTSamplingTableMeta& table = sample_meta[env_table_index];
    device const PathTraceEnvImportance* env_table =
        reinterpret_cast<device const PathTraceEnvImportance*>(sample_data + table.offset);
    uint entry_count = table.byte_size / uint(sizeof(PathTraceEnvImportance));
    if (entry_count == 0u) return make_invalid_direct_light_sample();

    uint select = min(entry_count - 1u, uint(hash_unit_float(seed ^ 0x3c84ef95u) * float(entry_count)));
    PathTraceEnvImportance entry = env_table[select];
    uint resolved = (hash_unit_float(seed ^ 0x7e6b2f31u) < entry.q) ? select : entry.alias;
    uint cell_x = resolved % params.environment_importance_width;
    uint cell_y = resolved / params.environment_importance_width;
    float u = (float(cell_x) + hash_unit_float(seed ^ 0x0f9d13c1u)) / float(params.environment_importance_width);
    float v = (float(cell_y) + hash_unit_float(seed ^ 0x92c313f7u)) / float(params.environment_importance_height);
    float3 direction = environment_uv_to_direction(u, v);
    float3 radiance = sample_texture_atlas(tex_atlas, tex_meta, params.environment_texture_index, u, v);
    float pdf = environment_direction_pdf(sample_data, sample_meta, params, env_table_index, direction);
    return PathTraceDirectLightSample{direction, radiance, pdf, 1e30f, 1u, 0u};
}

static PathTraceDirectLightSample sample_emissive_light(
    float3 hit_pos,
    uint current_tri_index,
    constant RTTriangle* triangles,
    device const uchar* sample_data,
    constant RTSamplingTableMeta* sample_meta,
    constant RTParams& params,
    int emissive_table_index,
    uint seed
) {
    if (emissive_table_index < 0 || params.emissive_total_area <= 0.0f) {
        return make_invalid_direct_light_sample();
    }
    constant RTSamplingTableMeta& table = sample_meta[emissive_table_index];
    device const PathTraceEmissiveLight* light_table =
        reinterpret_cast<device const PathTraceEmissiveLight*>(sample_data + table.offset);
    uint light_count = table.byte_size / uint(sizeof(PathTraceEmissiveLight));
    if (light_count == 0u) return make_invalid_direct_light_sample();

    float pick = hash_unit_float(seed ^ 0xe18f0c7bu);
    uint low = 0u;
    uint high = light_count;
    while (low < high) {
        uint mid = (low + high) / 2u;
        if (pick <= light_table[mid].cdf) {
            high = mid;
        } else {
            low = mid + 1u;
        }
    }
    uint chosen_index = min(low, light_count - 1u);
    PathTraceEmissiveLight light = light_table[chosen_index];
    if (light.triangle_index == current_tri_index) return make_invalid_direct_light_sample();

    constant RTTriangle& tri = triangles[light.triangle_index];
    float sqrt_r1 = sqrt(hash_unit_float(seed ^ 0x1451ad37u));
    float r2 = hash_unit_float(seed ^ 0x45a18bc5u);
    float b0 = 1.0f - sqrt_r1;
    float b1 = sqrt_r1 * (1.0f - r2);
    float b2 = sqrt_r1 * r2;
    float3 sample_pos =
        float3(tri.v0) * b0 +
        float3(tri.v1) * b1 +
        float3(tri.v2) * b2;
    float3 to_light = sample_pos - hit_pos;
    float distance = length(to_light);
    if (distance <= 0.002f) return make_invalid_direct_light_sample();
    float3 direction = to_light / distance;
    float3 light_normal = triangle_geometric_normal(tri);
    float cos_light = max(abs(dot(-direction, light_normal)), 0.0001f);
    float pdf = (distance * distance) / max(cos_light * params.emissive_total_area, 1e-6f);
    return PathTraceDirectLightSample{direction, float3(tri.emissive), pdf, distance, 1u, 0u};
}

static float emissive_direction_pdf(
    float3 origin,
    float3 hit_pos,
    constant RTTriangle& tri,
    float emissive_total_area
) {
    if (emissive_total_area <= 0.0f) return 0.0f;
    float3 to_light = hit_pos - origin;
    float distance_sq = dot(to_light, to_light);
    if (distance_sq <= 0.0f) return 0.0f;
    float3 direction = safe_normalize(to_light, float3(0.0f, 1.0f, 0.0f));
    float3 light_normal = triangle_geometric_normal(tri);
    float cos_light = max(abs(dot(-direction, light_normal)), 0.0001f);
    return distance_sq / max(cos_light * emissive_total_area, 1e-6f);
}

static bool point_light_active(float3 radiance, float range) {
    return max_component(radiance) > 0.0001f && range > 0.001f;
}

static PathTraceDirectLightSample sample_point_light(
    float3 hit_pos,
    float3 light_position,
    float3 light_radiance,
    float light_range
) {
    if (!point_light_active(light_radiance, light_range)) return make_invalid_direct_light_sample();

    float3 to_light = light_position - hit_pos;
    float distance = length(to_light);
    if (distance <= 0.002f || distance > light_range) return make_invalid_direct_light_sample();
    float falloff = clamp(1.0f - distance / max(light_range, 0.001f), 0.0f, 1.0f);
    float attenuation = falloff * falloff;
    if (attenuation <= 1e-5f) return make_invalid_direct_light_sample();
    return PathTraceDirectLightSample{
        to_light / distance,
        light_radiance * attenuation,
        1.0f,
        distance,
        1u,
        1u,
    };
}

static bool spot_light_active(float3 radiance, float range) {
    return max_component(radiance) > 0.0001f && range > 0.001f;
}

static PathTraceDirectLightSample sample_spot_light(
    float3 hit_pos,
    float3 light_position,
    float3 light_direction,
    float3 light_radiance,
    float light_range,
    float inner_angle_cos,
    float outer_angle_cos
) {
    if (!spot_light_active(light_radiance, light_range)) return make_invalid_direct_light_sample();

    float3 to_light = light_position - hit_pos;
    float distance = length(to_light);
    if (distance <= 0.002f || distance > light_range) return make_invalid_direct_light_sample();

    float3 direction = to_light / distance;
    float3 light_to_surface = -direction;
    float3 light_forward = safe_normalize(light_direction, float3(0.0f, 0.0f, -1.0f));
    float cone_cos = dot(light_forward, light_to_surface);
    if (cone_cos <= outer_angle_cos) return make_invalid_direct_light_sample();

    float falloff = clamp(1.0f - distance / max(light_range, 0.001f), 0.0f, 1.0f);
    float attenuation = falloff * falloff;
    float cone_factor = (cone_cos >= inner_angle_cos)
        ? 1.0f
        : clamp((cone_cos - outer_angle_cos) / max(inner_angle_cos - outer_angle_cos, 1e-4f), 0.0f, 1.0f);
    float intensity = attenuation * cone_factor;
    if (intensity <= 1e-5f) return make_invalid_direct_light_sample();

    return PathTraceDirectLightSample{
        direction,
        light_radiance * intensity,
        1.0f,
        distance,
        1u,
        1u,
    };
}

static uint direct_light_type_count(
    constant RTParams& params,
    bool has_environment_sampling,
    bool has_emissive_sampling
) {
    uint count = 0u;
    for (uint i = 0u; i < params.directional_light_count && i < 4u; i++) {
        if (max_component(float3(params.directional_light_radiance[i])) > 0.0001f) {
            count += 1u;
        }
    }
    for (uint i = 0u; i < params.point_light_count && i < 16u; i++) {
        if (point_light_active(float3(params.point_light_radiance[i]), params.point_light_ranges[i])) {
            count += 1u;
        }
    }
    for (uint i = 0u; i < params.spot_light_count && i < 16u; i++) {
        if (spot_light_active(float3(params.spot_light_radiance[i]), params.spot_light_ranges[i])) {
            count += 1u;
        }
    }
    if (has_environment_sampling) count += 1u;
    if (has_emissive_sampling && params.emissive_total_area > 0.0f) count += 1u;
    return count;
}

static PathTraceDirectLightSample sample_direct_light(
    float3 hit_pos,
    uint current_tri_index,
    constant RTTriangle* triangles,
    device const uchar* tex_atlas,
    constant RTTextureMeta* tex_meta,
    device const uchar* sample_data,
    constant RTSamplingTableMeta* sample_meta,
    constant RTParams& params,
    int env_table_index,
    int emissive_table_index,
    uint seed
) {
    bool has_environment_sampling =
        params.environment_texture_index >= 0 &&
        env_table_index >= 0 &&
        params.environment_importance_width > 0u &&
        params.environment_importance_height > 0u;
    bool has_emissive_sampling = emissive_table_index >= 0 && params.emissive_total_area > 0.0f;
    uint light_type_count = direct_light_type_count(params, has_environment_sampling, has_emissive_sampling);
    if (light_type_count == 0u) return make_invalid_direct_light_sample();

    uint selection = min(light_type_count - 1u, uint(hash_unit_float(seed ^ 0xa241b3c1u) * float(light_type_count)));
    uint cursor = 0u;
    for (uint i = 0u; i < params.directional_light_count && i < 4u; i++) {
        if (max_component(float3(params.directional_light_radiance[i])) <= 0.0001f) continue;
        if (selection == cursor) {
            return PathTraceDirectLightSample{
                safe_normalize(float3(params.directional_light_directions[i]), float3(0.0f, 1.0f, 0.0f)),
                float3(params.directional_light_radiance[i]),
                1.0f / float(light_type_count),
                1e30f,
                1u,
                1u,
            };
        }
        cursor += 1u;
    }
    for (uint i = 0u; i < params.point_light_count && i < 16u; i++) {
        if (!point_light_active(float3(params.point_light_radiance[i]), params.point_light_ranges[i])) continue;
        if (selection == cursor) {
            PathTraceDirectLightSample sample = sample_point_light(
                hit_pos,
                float3(params.point_light_positions[i]),
                float3(params.point_light_radiance[i]),
                params.point_light_ranges[i]
            );
            if (sample.valid != 0u) {
                sample.pdf = 1.0f / float(light_type_count);
            }
            return sample;
        }
        cursor += 1u;
    }
    for (uint i = 0u; i < params.spot_light_count && i < 16u; i++) {
        if (!spot_light_active(float3(params.spot_light_radiance[i]), params.spot_light_ranges[i])) continue;
        if (selection == cursor) {
            PathTraceDirectLightSample sample = sample_spot_light(
                hit_pos,
                float3(params.spot_light_positions[i]),
                float3(params.spot_light_directions[i]),
                float3(params.spot_light_radiance[i]),
                params.spot_light_ranges[i],
                params.spot_light_inner_angle_cos[i],
                params.spot_light_outer_angle_cos[i]
            );
            if (sample.valid != 0u) {
                sample.pdf = 1.0f / float(light_type_count);
            }
            return sample;
        }
        cursor += 1u;
    }
    if (has_environment_sampling) {
        if (selection == cursor) {
            PathTraceDirectLightSample sample = sample_environment_light(
                tex_atlas,
                tex_meta,
                sample_data,
                sample_meta,
                params,
                env_table_index,
                seed ^ 0x6b84221fu
            );
            if (sample.valid != 0u) {
                sample.pdf *= 1.0f / float(light_type_count);
            }
            return sample;
        }
        cursor += 1u;
    }
    if (has_emissive_sampling && selection == cursor) {
        PathTraceDirectLightSample sample = sample_emissive_light(
            hit_pos,
            current_tri_index,
            triangles,
            sample_data,
            sample_meta,
            params,
            emissive_table_index,
            seed ^ 0xb5297a4du
        );
        if (sample.valid != 0u) {
            sample.pdf *= 1.0f / float(light_type_count);
        }
        return sample;
    }
    return make_invalid_direct_light_sample();
}

static uint path_trace_adaptive_min_samples(uint max_samples) {
    if (max_samples <= 2u) return max_samples;
    if (max_samples <= 4u) return 2u;
    return min(max_samples, 4u);
}

static float path_trace_adaptive_noise_metric(float sum, float sum_sq, uint sample_count) {
    if (sample_count == 0u) return 0.0f;
    float sample_count_f = float(sample_count);
    float mean = sum / sample_count_f;
    float variance = max(0.0f, sum_sq / sample_count_f - mean * mean);
    return variance / max(mean * mean, 1e-4f);
}

static uint path_trace_adaptive_target_samples(uint max_samples, float tile_noise_metric) {
    uint min_samples = path_trace_adaptive_min_samples(max_samples);
    if (max_samples <= min_samples) return max_samples;
    uint remaining = max_samples - min_samples;
    uint medium_samples = min(max_samples, min_samples + max(1u, (remaining + 1u) / 2u));
    if (tile_noise_metric <= 0.015f) return min_samples;
    if (tile_noise_metric <= 0.06f) return medium_samples;
    return max_samples;
}

static float3 trace_path_sample(
    uint2 tid,
    uint pixel_seed,
    uint sample_index,
    constant RTParams& params,
    constant RTTriangle* triangles,
    primitive_acceleration_structure accel,
    device const uchar* tex_atlas,
    constant RTTextureMeta* tex_meta,
    device const uchar* sample_data,
    constant RTSamplingTableMeta* sample_meta,
    int env_table_index,
    int emissive_table_index,
    bool has_environment_sampling,
    bool has_emissive_sampling
) {
    uint sseed = pixel_seed ^ (sample_index * 0x45d9f3bu);
    float jx = hash_unit_float(sseed ^ 0x18f0e149u) - 0.5f;
    float jy = hash_unit_float(sseed ^ 0x6c8e9cf5u) - 0.5f;
    float2 uv = (float2(tid) + 0.5f + float2(jx, jy)) / float2(params.dimensions);
    float ndc_x = uv.x * 2.0f - 1.0f;
    float ndc_y = 1.0f - uv.y * 2.0f;

    float4 wnear = params.inv_view_projection * float4(ndc_x, ndc_y, 0.0f, 1.0f);
    float4 wfar  = params.inv_view_projection * float4(ndc_x, ndc_y, 1.0f, 1.0f);
    float inv_wn = (abs(wnear.w) > 1e-6f) ? (1.0f / wnear.w) : 1.0f;
    float inv_wf = (abs(wfar.w)  > 1e-6f) ? (1.0f / wfar.w)  : 1.0f;
    float3 near_pos = wnear.xyz * inv_wn;
    float3 far_pos  = wfar.xyz  * inv_wf;
    float3 origin = float3(params.camera_origin);
    float3 direction = normalize(far_pos - near_pos);
    if (length(direction) <= 1e-4f) direction = normalize(far_pos - origin);

    float3 throughput = float3(1.0f);
    float3 radiance   = float3(0.0f);
    float previous_bsdf_pdf = 0.0f;
    bool previous_was_delta = true;
    intersector<triangle_data> inter;
    inter.accept_any_intersection(false);

    for (uint bounce = 0; bounce < params.bounces; bounce++) {
        ray r;
        r.origin       = origin;
        r.direction    = direction;
        r.min_distance = 0.001f;
        r.max_distance = 1e30f;

        auto hit = inter.intersect(r, accel);
        if (hit.type != intersection_type::triangle) {
            float3 sky = sample_environment(tex_atlas, tex_meta, params.environment_texture_index, direction);
            if (bounce == 0u || previous_was_delta || !has_environment_sampling) {
                radiance += throughput * sky;
            } else {
                uint light_type_count = direct_light_type_count(params, has_environment_sampling, has_emissive_sampling);
                float env_select_pdf = (light_type_count > 0u && has_environment_sampling) ? (1.0f / float(light_type_count)) : 0.0f;
                float env_pdf = env_select_pdf * environment_direction_pdf(sample_data, sample_meta, params, env_table_index, direction);
                float mis = power_heuristic(previous_bsdf_pdf, env_pdf);
                radiance += throughput * sky * mis;
            }
            break;
        }

        uint pid = hit.primitive_id;
        constant RTTriangle& tri = triangles[pid];
        float2 bary = hit.triangle_barycentric_coord;
        float w0 = 1.0f - bary.x - bary.y;
        float3 interpolated_normal = safe_normalize(
            float3(tri.n0) * w0 + float3(tri.n1) * bary.x + float3(tri.n2) * bary.y,
            float3(0.0f, 1.0f, 0.0f)
        );
        float3 geometric_normal_raw = triangle_geometric_normal(tri);
        bool front_face = dot(direction, geometric_normal_raw) < 0.0f;
        float3 geometric_normal = front_face ? geometric_normal_raw : -geometric_normal_raw;
        float3 shade_n = front_face ? interpolated_normal : -interpolated_normal;
        float3 view_dir = -direction;
        float3 hit_pos = origin + direction * hit.distance;

        float2 hit_uv = float2(tri.uv0) * w0 + float2(tri.uv1) * bary.x + float2(tri.uv2) * bary.y;
        float3 alb = float3(tri.albedo);
        if (tri.base_color_texture_index >= 0) {
            alb *= sample_texture_atlas(tex_atlas, tex_meta, tri.base_color_texture_index, hit_uv.x, hit_uv.y);
        }
        if (tri.occlusion_texture_index >= 0) {
            float ao = clamp(sample_texture_atlas_raw(tex_atlas, tex_meta, tri.occlusion_texture_index, hit_uv.x, hit_uv.y).x, 0.0f, 1.0f);
            alb *= ao;
        }

        float3 emis = float3(tri.emissive);
        if (tri.emissive_texture_index >= 0) {
            emis *= sample_texture_atlas(tex_atlas, tex_meta, tri.emissive_texture_index, hit_uv.x, hit_uv.y);
        }
        float met = tri.metallic;
        float rough = tri.roughness;
        if (tri.metallic_roughness_texture_index >= 0) {
            float4 mr = sample_texture_atlas_raw(tex_atlas, tex_meta, tri.metallic_roughness_texture_index, hit_uv.x, hit_uv.y);
            met = clamp(met * mr.z, 0.0f, 1.0f);
            rough = clamp(rough * mr.y, 0.04f, 1.0f);
        }
        if (tri.normal_texture_index >= 0) {
            float3 tangent_space_normal = safe_normalize(
                sample_texture_atlas_raw(tex_atlas, tex_meta, tri.normal_texture_index, hit_uv.x, hit_uv.y).xyz * 2.0f - 1.0f,
                float3(0.0f, 0.0f, 1.0f)
            );
            RTTangentFrame frame = build_triangle_tangent_frame(tri, shade_n);
            float3 mapped_normal = safe_normalize(
                frame.tangent * tangent_space_normal.x +
                frame.bitangent * tangent_space_normal.y +
                frame.normal * tangent_space_normal.z,
                shade_n
            );
            if (dot(mapped_normal, geometric_normal) > 0.0f) {
                shade_n = mapped_normal;
            }
        }
        float transmission = clamp(tri.transmission, 0.0f, 0.98f);

        if (params.mode == 1u) {
            float3 L = safe_normalize(float3(params.light_direction), float3(0.0f, 1.0f, 0.0f));
            uint n_shadow = max(1u, params.shadow_samples);
            float total_vis = 0.0f;
            for (uint si = 0; si < n_shadow; si++) {
                uint sseed2 = pixel_seed ^ (si * 0x9e3779b9u) ^ 0xa1b2c3d4u;
                float3 jittered_L = sample_cone(L, params.sun_angular_radius, sseed2);
                ray shadow_ray;
                shadow_ray.origin       = hit_pos + geometric_normal * 0.002f;
                shadow_ray.direction    = jittered_L;
                shadow_ray.min_distance = 0.001f;
                shadow_ray.max_distance = 1e30f;
                intersector<triangle_data> shadow_inter;
                shadow_inter.accept_any_intersection(true);
                auto shadow_hit = shadow_inter.intersect(shadow_ray, accel);
                total_vis += (shadow_hit.type == intersection_type::triangle) ? 0.0f : 1.0f;
            }
            return float3(total_vis / float(n_shadow));
        }

        if (max_component(emis) > 0.0001f) {
            if (bounce == 0u || previous_was_delta) {
                radiance += throughput * emis;
            } else {
                uint light_type_count = direct_light_type_count(params, has_environment_sampling, has_emissive_sampling);
                float emissive_select_pdf =
                    (light_type_count > 0u && has_emissive_sampling) ? (1.0f / float(light_type_count)) : 0.0f;
                float light_pdf = emissive_select_pdf * emissive_direction_pdf(origin, hit_pos, tri, params.emissive_total_area);
                float mis = power_heuristic(previous_bsdf_pdf, light_pdf);
                radiance += throughput * emis * mis;
            }
        }

        if (transmission < 0.995f) {
            PathTraceDirectLightSample light_sample = sample_direct_light(
                hit_pos,
                pid,
                triangles,
                tex_atlas,
                tex_meta,
                sample_data,
                sample_meta,
                params,
                env_table_index,
                emissive_table_index,
                sseed ^ (bounce * 0x9e3779b9u)
            );
            if (light_sample.valid != 0u) {
                float occlusion_distance = (light_sample.distance >= 1.0e29f)
                    ? 1e30f
                    : max(light_sample.distance - 0.004f, 0.001f);
                ray shadow_ray;
                shadow_ray.origin = hit_pos + shade_n * 0.002f;
                shadow_ray.direction = light_sample.direction;
                shadow_ray.min_distance = 0.001f;
                shadow_ray.max_distance = occlusion_distance;
                intersector<triangle_data> shadow_inter;
                shadow_inter.accept_any_intersection(true);
                auto shadow_hit = shadow_inter.intersect(shadow_ray, accel);
                if (shadow_hit.type != intersection_type::triangle) {
                    PathTraceBsdfEval bsdf = evaluate_opaque_bsdf(
                        alb,
                        met,
                        rough,
                        transmission,
                        shade_n,
                        view_dir,
                        light_sample.direction
                    );
                    if (bsdf.pdf > 0.0f) {
                        float n_dot_l = saturate(dot(shade_n, light_sample.direction));
                        float mis = (light_sample.delta != 0u) ? 1.0f : power_heuristic(light_sample.pdf, bsdf.pdf);
                        radiance += throughput * bsdf.value * light_sample.radiance *
                            ((n_dot_l * mis) / max(light_sample.pdf, 1e-6f));
                    }
                }
            }
        }

        float transmission_branch_prob = clamp(transmission * (1.0f - met), 0.0f, 0.98f);
        float opaque_branch_prob = 1.0f - transmission_branch_prob;
        uint branch_seed = sseed ^ (bounce * 0x85ebca6bu);

        if (transmission_branch_prob > 0.0f && hash_unit_float(branch_seed ^ 0x1451ad37u) < transmission_branch_prob) {
            float eta = front_face ? (1.0f / max(tri.ior, 1.01f)) : max(tri.ior, 1.01f);
            float3 dielectric_f0 = float3(0.04f);
            float3 fresnel = fresnel_schlick(saturate(dot(shade_n, view_dir)), dielectric_f0);
            float reflect_prob = clamp(luminance(fresnel), 0.05f, 0.95f);
            float3 reflected = safe_normalize(reflect_vec(direction, shade_n), shade_n);
            float3 refr_dir;

            if (!refract_vec(direction, shade_n, eta, refr_dir) || hash_unit_float(branch_seed ^ 0x45a18bc5u) < reflect_prob) {
                throughput = throughput * fresnel / max(transmission_branch_prob * reflect_prob, 1e-6f);
                direction = reflected;
                origin = hit_pos + shade_n * 0.002f;
            } else {
                float3 transmission_tint = mix(float3(1.0f), alb, 0.18f);
                throughput = throughput * (transmission_tint * one_minus(fresnel)) /
                    max(transmission_branch_prob * (1.0f - reflect_prob), 1e-6f);
                direction = safe_normalize(refr_dir, -shade_n);
                if (tri.thickness > 1e-4f) {
                    float ndot = max(abs(dot(direction, shade_n)), 0.2f);
                    float optical_distance = tri.thickness / ndot;
                    float3 sigma_a = max(float3(0.0f), 1.0f - alb) * 2.2f;
                    throughput *= exp(-sigma_a * optical_distance);
                }
                origin = hit_pos + direction * 0.002f;
            }
            previous_bsdf_pdf = 1.0f;
            previous_was_delta = true;
        } else if (opaque_branch_prob > 0.0f) {
            float3 dielectric_f0 = float3(0.04f);
            float3 f0 = mix(dielectric_f0, alb, met);
            float3 fresnel_view = fresnel_schlick(saturate(dot(shade_n, view_dir)), f0);
            PathTraceLobeProbabilities lobe_probs = compute_opaque_lobe_probabilities(alb, met, transmission, fresnel_view);
            bool choose_specular = hash_unit_float(branch_seed ^ 0x92c313f7u) < lobe_probs.specular;
            float3 next_direction;

            if (choose_specular) {
                float3 half_vector = sample_ggx_visible_half_vector(shade_n, view_dir, rough, branch_seed ^ 0x6b84221fu);
                next_direction = safe_normalize(reflect_vec(-view_dir, half_vector), shade_n);
                if (dot(next_direction, shade_n) <= 0.0f) break;
            } else {
                next_direction = sample_cosine_hemisphere(shade_n, branch_seed ^ 0xb5297a4du);
            }

            PathTraceBsdfEval bsdf = evaluate_opaque_bsdf(
                alb,
                met,
                rough,
                transmission,
                shade_n,
                view_dir,
                next_direction
            );
            float n_dot_l = saturate(dot(shade_n, next_direction));
            float overall_pdf = opaque_branch_prob * bsdf.pdf;
            if (overall_pdf <= 0.0f || n_dot_l <= 0.0f) break;

            throughput = throughput * bsdf.value * (n_dot_l / overall_pdf);
            direction = next_direction;
            origin = hit_pos + shade_n * 0.002f;
            previous_bsdf_pdf = overall_pdf;
            previous_was_delta = false;
        } else {
            break;
        }

        if (bounce >= 2u) {
            float survival_prob = min(max_component(throughput), 0.95f);
            if (survival_prob <= 0.0f || hash_unit_float(sseed ^ (bounce * 0xc2b2ae35u)) > survival_prob) {
                break;
            }
            throughput /= survival_prob;
        }
    }

    return radiance;
}

kernel void raytrace_kernel(
    uint2                          tid        [[thread_position_in_grid]],
    uint2                          tid_group  [[thread_position_in_threadgroup]],
    constant RTParams&             params     [[buffer(0)]],
    device uchar*                  output     [[buffer(1)]],
    constant RTTriangle*           triangles  [[buffer(2)]],
    primitive_acceleration_structure accel     [[buffer(3)]],
    device const uchar*            tex_atlas  [[buffer(4)]],
    constant RTTextureMeta*        tex_meta   [[buffer(5)]],
    device const uchar*            sample_data [[buffer(6)]],
    constant RTSamplingTableMeta*  sample_meta [[buffer(7)]]
) {
    const bool valid_pixel = tid.x < params.dimensions.x && tid.y < params.dimensions.y;
    const bool use_adaptive_sampling = params.mode == 0u && params.samples > 1u;
    const uint adaptive_min_samples = use_adaptive_sampling ? path_trace_adaptive_min_samples(params.samples) : params.samples;
    const uint local_index = tid_group.y * 8u + tid_group.x;
    threadgroup float tile_luminance_sum[64];
    threadgroup float tile_luminance_sum_sq[64];
    threadgroup uint tile_sample_count[64];
    threadgroup uint tile_target_samples;

    float3 accumulated = float3(0.0f);
    uint pixel_seed = hash_u32(tid.x ^ (tid.y << 16) ^ 0x7f4a7c15u);
    const int env_table_index = find_sampling_table(sample_meta, params.sampling_table_count, RT_SAMPLING_TABLE_ENVIRONMENT_IMPORTANCE);
    const int emissive_table_index = find_sampling_table(sample_meta, params.sampling_table_count, RT_SAMPLING_TABLE_EMISSIVE_LIGHT);
    const bool has_environment_sampling =
        params.environment_texture_index >= 0 &&
        env_table_index >= 0 &&
        params.environment_importance_width > 0u &&
        params.environment_importance_height > 0u;
    const bool has_emissive_sampling =
        emissive_table_index >= 0 &&
        params.emissive_total_area > 0.0f;

    float luminance_sum = 0.0f;
    float luminance_sum_sq = 0.0f;
    if (valid_pixel) {
        for (uint s = 0; s < adaptive_min_samples; s++) {
            float3 sample_radiance = trace_path_sample(
                tid,
                pixel_seed,
                s,
                params,
                triangles,
                accel,
                tex_atlas,
                tex_meta,
                sample_data,
                sample_meta,
                env_table_index,
                emissive_table_index,
                has_environment_sampling,
                has_emissive_sampling
            );
            accumulated += sample_radiance;
            if (use_adaptive_sampling) {
                float sample_luminance = luminance(sample_radiance);
                luminance_sum += sample_luminance;
                luminance_sum_sq += sample_luminance * sample_luminance;
            }
        }
    }

    uint target_samples = params.samples;
    if (use_adaptive_sampling) {
        tile_luminance_sum[local_index] = valid_pixel ? luminance_sum : 0.0f;
        tile_luminance_sum_sq[local_index] = valid_pixel ? luminance_sum_sq : 0.0f;
        tile_sample_count[local_index] = valid_pixel ? adaptive_min_samples : 0u;
        if (local_index == 0u) {
            tile_target_samples = params.samples;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint stride = 32u; stride > 0u; stride >>= 1u) {
            if (local_index < stride) {
                tile_luminance_sum[local_index] += tile_luminance_sum[local_index + stride];
                tile_luminance_sum_sq[local_index] += tile_luminance_sum_sq[local_index + stride];
                tile_sample_count[local_index] += tile_sample_count[local_index + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (local_index == 0u) {
            float tile_noise_metric = path_trace_adaptive_noise_metric(
                tile_luminance_sum[0],
                tile_luminance_sum_sq[0],
                tile_sample_count[0]
            );
            tile_target_samples = path_trace_adaptive_target_samples(params.samples, tile_noise_metric);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        target_samples = tile_target_samples;
    }

    if (valid_pixel) {
        for (uint s = adaptive_min_samples; s < target_samples; s++) {
            accumulated += trace_path_sample(
                tid,
                pixel_seed,
                s,
                params,
                triangles,
                accel,
                tex_atlas,
                tex_meta,
                sample_data,
                sample_meta,
                env_table_index,
                emissive_table_index,
                has_environment_sampling,
                has_emissive_sampling
            );
        }
        accumulated /= float(max(target_samples, 1u));
    }

    if (!valid_pixel) return;

    uint idx = tid.y * params.dimensions.x + tid.x;
    if (params.mode == 1) {
        // shadow-only: output grayscale visibility (no gamma, linear)
        uchar v = uchar(saturate(accumulated.x) * 255.0f);
        uint base = idx * 4;
        output[base + 0] = v;
        output[base + 1] = v;
        output[base + 2] = v;
        output[base + 3] = 255;
    } else if (params.output_is_half != 0u) {
        device half* output_half = (device half*)output;
        uint hbase = idx * 4;
        output_half[hbase + 0] = half(clamp(accumulated.x, -65504.0f, 65504.0f));
        output_half[hbase + 1] = half(clamp(accumulated.y, -65504.0f, 65504.0f));
        output_half[hbase + 2] = half(clamp(accumulated.z, -65504.0f, 65504.0f));
        output_half[hbase + 3] = half(1.0f);
    } else {
        float3 linear = saturate(accumulated);
        uint base = idx * 4;
        output[base + 0] = uchar(linear.z * 255.0f);  // B
        output[base + 1] = uchar(linear.y * 255.0f);  // G
        output[base + 2] = uchar(linear.x * 255.0f);  // R
        output[base + 3] = 255;
    }
}
)METAL";

// ---------------------------------------------------------------------------
// GuavaMetalRTContext — 持有所有 Metal 资源
// ---------------------------------------------------------------------------
struct GuavaMetalRTContext {
    id<MTLDevice>                   device;
    id<MTLCommandQueue>             commandQueue;
    id<MTLComputePipelineState>     pipeline;
    id<MTLAccelerationStructure>    accel;
    id<MTLBuffer>                   vertexPositionBuffer;
    id<MTLBuffer>                   triangleDataBuffer;
    id<MTLBuffer>                   outputBuffer;
    id<MTLBuffer>                   paramsBuffer;
    id<MTLBuffer>                   textureAtlasBuffer;
    id<MTLBuffer>                   textureMetaBuffer;
    id<MTLBuffer>                   samplingTableBuffer;
    id<MTLBuffer>                   samplingTableMetaBuffer;
    uint32_t                        triangleCount;
    uint32_t                        outputWidth;
    uint32_t                        outputHeight;
    uint32_t                        outputBytesPerPixel;
    uint32_t                        textureCount;
    uint32_t                        samplingTableCount;
    bool                            supported;
    bool                            accelBuilt;
};

// ---------------------------------------------------------------------------
// guava_metal_rt_init
// ---------------------------------------------------------------------------
extern "C" GuavaMetalRTContext* guava_metal_rt_init(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[Metal RT] MTLCreateSystemDefaultDevice failed\n");
            return nullptr;
        }

        if (![device supportsRaytracing]) {
            fprintf(stderr, "[Metal RT] Device does not support ray tracing\n");
            return nullptr;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) {
            fprintf(stderr, "[Metal RT] Failed to create command queue\n");
            return nullptr;
        }

        // Compile MSL shader
        NSError* error = nil;
        MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;

        NSString* source = [NSString stringWithUTF8String:kMetalRTShaderSource];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:opts error:&error];
        if (!library) {
            fprintf(stderr, "[Metal RT] Shader compile failed: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nullptr;
        }

        id<MTLFunction> kernelFunc = [library newFunctionWithName:@"raytrace_kernel"];
        if (!kernelFunc) {
            fprintf(stderr, "[Metal RT] raytrace_kernel function not found\n");
            return nullptr;
        }

        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:kernelFunc error:&error];
        if (!pipeline) {
            fprintf(stderr, "[Metal RT] Pipeline creation failed: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nullptr;
        }

        auto* ctx         = new GuavaMetalRTContext();
        ctx->device        = device;
        ctx->commandQueue  = queue;
        ctx->pipeline      = pipeline;
        ctx->accel         = nil;
        ctx->vertexPositionBuffer = nil;
        ctx->triangleDataBuffer   = nil;
        ctx->outputBuffer  = nil;
        ctx->paramsBuffer  = nil;
        ctx->textureAtlasBuffer = nil;
        ctx->textureMetaBuffer  = nil;
        ctx->samplingTableBuffer = nil;
        ctx->samplingTableMetaBuffer = nil;
        ctx->triangleCount = 0;
        ctx->outputWidth   = 0;
        ctx->outputHeight  = 0;
        ctx->outputBytesPerPixel = 0;
        ctx->textureCount  = 0;
        ctx->samplingTableCount = 0;
        ctx->supported     = true;
        ctx->accelBuilt    = false;

        fprintf(stderr, "[Metal RT] Initialized — device: %s\n",
                [[device name] UTF8String]);
        return ctx;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_is_supported
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_is_supported(GuavaMetalRTContext* ctx) {
    return ctx && ctx->supported;
}

// ---------------------------------------------------------------------------
// guava_metal_rt_build_accel
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_build_accel(GuavaMetalRTContext* ctx,
                                           const GuavaRTTriangle* triangles,
                                           uint32_t triangle_count) {
    if (!ctx || !ctx->supported || triangle_count == 0) return false;

    @autoreleasepool {
        id<MTLDevice> dev = ctx->device;

        // ---- 1. 提取顶点位置到紧凑 buffer ----
        const uint32_t vertex_count  = triangle_count * 3;
        const size_t   pos_buf_size  = (size_t)vertex_count * sizeof(float) * 3;
        id<MTLBuffer>  posBuf = [dev newBufferWithLength:pos_buf_size
                                                 options:MTLResourceStorageModeShared];
        if (!posBuf) return false;

        float* dst = (float*)[posBuf contents];
        for (uint32_t i = 0; i < triangle_count; i++) {
            memcpy(&dst[i * 9 + 0], triangles[i].v0, 12);
            memcpy(&dst[i * 9 + 3], triangles[i].v1, 12);
            memcpy(&dst[i * 9 + 6], triangles[i].v2, 12);
        }

        // ---- 2. 三角形材质 buffer（着色用） ----
        const size_t tri_buf_size = (size_t)triangle_count * sizeof(GuavaRTTriangle);
        id<MTLBuffer> triDataBuf = [dev newBufferWithBytes:triangles
                                                    length:tri_buf_size
                                                   options:MTLResourceStorageModeShared];
        if (!triDataBuf) return false;

        // ---- 3. 加速结构描述 ----
        MTLAccelerationStructureTriangleGeometryDescriptor* geomDesc =
            [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
        geomDesc.vertexBuffer       = posBuf;
        geomDesc.vertexBufferOffset = 0;
        geomDesc.vertexStride       = sizeof(float) * 3;
        geomDesc.triangleCount      = triangle_count;

        MTLPrimitiveAccelerationStructureDescriptor* asDesc =
            [MTLPrimitiveAccelerationStructureDescriptor descriptor];
        asDesc.geometryDescriptors = @[ geomDesc ];

        MTLAccelerationStructureSizes sizes =
            [dev accelerationStructureSizesWithDescriptor:asDesc];

        id<MTLAccelerationStructure> accelStruct =
            [dev newAccelerationStructureWithSize:sizes.accelerationStructureSize];
        if (!accelStruct) return false;

        id<MTLBuffer> scratch = [dev newBufferWithLength:sizes.buildScratchBufferSize
                                                 options:MTLResourceStorageModePrivate];
        if (!scratch) return false;

        // ---- 4. 构建 ----
        id<MTLCommandBuffer> cmdBuf = [ctx->commandQueue commandBuffer];
        id<MTLAccelerationStructureCommandEncoder> enc =
            [cmdBuf accelerationStructureCommandEncoder];
        [enc buildAccelerationStructure:accelStruct
                             descriptor:asDesc
                          scratchBuffer:scratch
                    scratchBufferOffset:0];
        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status == MTLCommandBufferStatusError) {
            fprintf(stderr, "[Metal RT] AS build failed: %s\n",
                    [[cmdBuf.error localizedDescription] UTF8String]);
            return false;
        }

        // ---- 5. 保存到 ctx ----
        ctx->accel                = accelStruct;
        ctx->vertexPositionBuffer = posBuf;
        ctx->triangleDataBuffer   = triDataBuf;
        ctx->triangleCount        = triangle_count;
        ctx->accelBuilt           = true;
        return true;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_upload_textures
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_upload_textures(GuavaMetalRTContext* ctx,
                                               const uint8_t* pixel_data,
                                               uint32_t pixel_data_size,
                                               const GuavaRTTextureMeta* meta,
                                               uint32_t texture_count) {
    if (!ctx || !ctx->supported) return false;
    if (texture_count == 0 || !pixel_data || pixel_data_size == 0) {
        ctx->textureAtlasBuffer = nil;
        ctx->textureMetaBuffer  = nil;
        ctx->textureCount       = 0;
        return true;
    }

    @autoreleasepool {
        id<MTLDevice> dev = ctx->device;

        ctx->textureAtlasBuffer = [dev newBufferWithBytes:pixel_data
                                                   length:pixel_data_size
                                                  options:MTLResourceStorageModeShared];
        if (!ctx->textureAtlasBuffer) return false;

        ctx->textureMetaBuffer = [dev newBufferWithBytes:meta
                                                  length:(size_t)texture_count * sizeof(GuavaRTTextureMeta)
                                                 options:MTLResourceStorageModeShared];
        if (!ctx->textureMetaBuffer) return false;

        ctx->textureCount = texture_count;
        return true;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_upload_sampling_tables
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_upload_sampling_tables(GuavaMetalRTContext* ctx,
                                                      const uint8_t* table_data,
                                                      uint32_t table_data_size,
                                                      const GuavaRTSamplingTableMeta* meta,
                                                      uint32_t table_count) {
    if (!ctx || !ctx->supported) return false;
    if (table_count == 0 || !table_data || table_data_size == 0) {
        ctx->samplingTableBuffer = nil;
        ctx->samplingTableMetaBuffer = nil;
        ctx->samplingTableCount = 0;
        return true;
    }

    @autoreleasepool {
        id<MTLDevice> dev = ctx->device;

        ctx->samplingTableBuffer = [dev newBufferWithBytes:table_data
                                                    length:table_data_size
                                                   options:MTLResourceStorageModeShared];
        if (!ctx->samplingTableBuffer) return false;

        ctx->samplingTableMetaBuffer = [dev newBufferWithBytes:meta
                                                         length:(size_t)table_count * sizeof(GuavaRTSamplingTableMeta)
                                                        options:MTLResourceStorageModeShared];
        if (!ctx->samplingTableMetaBuffer) return false;

        ctx->samplingTableCount = table_count;
        return true;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_trace
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_trace(GuavaMetalRTContext* ctx,
                                     const GuavaRTParams* params,
                                     uint8_t* output_pixels,
                                     uint32_t output_size) {
    if (!ctx || !ctx->accelBuilt || !params || !output_pixels) return false;

    @autoreleasepool {
        const uint32_t w = params->width;
        const uint32_t h = params->height;
        const uint32_t bytes_per_pixel = (params->mode == 1) ? 4 : ((params->output_is_half != 0) ? 8 : 4);
        const uint32_t needed = w * h * bytes_per_pixel;
        if (output_size < needed) return false;

        id<MTLDevice> dev = ctx->device;

        // ---- output buffer ----
        if (!ctx->outputBuffer || ctx->outputWidth != w || ctx->outputHeight != h || ctx->outputBytesPerPixel != bytes_per_pixel) {
            ctx->outputBuffer = [dev newBufferWithLength:needed
                                                 options:MTLResourceStorageModeShared];
            if (!ctx->outputBuffer) return false;
            ctx->outputWidth  = w;
            ctx->outputHeight = h;
            ctx->outputBytesPerPixel = bytes_per_pixel;
        }

        // ---- params buffer ----
        if (!ctx->paramsBuffer || [ctx->paramsBuffer length] != sizeof(GuavaRTParams)) {
            ctx->paramsBuffer = [dev newBufferWithLength:sizeof(GuavaRTParams)
                                                 options:MTLResourceStorageModeShared];
            if (!ctx->paramsBuffer) return false;
        }
        memcpy([ctx->paramsBuffer contents], params, sizeof(GuavaRTParams));

        // ---- dispatch ----
        id<MTLCommandBuffer> cmdBuf = [ctx->commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

        [enc setComputePipelineState:ctx->pipeline];
        [enc setBuffer:ctx->paramsBuffer       offset:0 atIndex:0];
        [enc setBuffer:ctx->outputBuffer       offset:0 atIndex:1];
        [enc setBuffer:ctx->triangleDataBuffer offset:0 atIndex:2];
        [enc setAccelerationStructure:ctx->accel atBufferIndex:3];

        // 纹理图集 + 元数据 (可选 — 无纹理时绑定空 1 字节缓冲)
        if (ctx->textureAtlasBuffer && ctx->textureMetaBuffer && ctx->textureCount > 0) {
            [enc setBuffer:ctx->textureAtlasBuffer offset:0 atIndex:4];
            [enc setBuffer:ctx->textureMetaBuffer  offset:0 atIndex:5];
        } else {
            // 绑定空缓冲避免 Metal 验证错误
            static id<MTLBuffer> emptyBuf = nil;
            if (!emptyBuf) {
                emptyBuf = [ctx->device newBufferWithLength:16
                                                    options:MTLResourceStorageModeShared];
            }
            [enc setBuffer:emptyBuf offset:0 atIndex:4];
            [enc setBuffer:emptyBuf offset:0 atIndex:5];
        }

        if (ctx->samplingTableBuffer && ctx->samplingTableMetaBuffer && ctx->samplingTableCount > 0) {
            [enc setBuffer:ctx->samplingTableBuffer offset:0 atIndex:6];
            [enc setBuffer:ctx->samplingTableMetaBuffer offset:0 atIndex:7];
        } else {
            static id<MTLBuffer> emptyBuf = nil;
            if (!emptyBuf) {
                emptyBuf = [ctx->device newBufferWithLength:16
                                                    options:MTLResourceStorageModeShared];
            }
            [enc setBuffer:emptyBuf offset:0 atIndex:6];
            [enc setBuffer:emptyBuf offset:0 atIndex:7];
        }

        // Metal 要求 compute encoder 声明加速结构引用的资源
        [enc useResource:ctx->vertexPositionBuffer usage:MTLResourceUsageRead];

        MTLSize gridSize  = MTLSizeMake(w, h, 1);
        MTLSize groupSize = MTLSizeMake(8, 8, 1);
        [enc dispatchThreads:gridSize threadsPerThreadgroup:groupSize];
        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status == MTLCommandBufferStatusError) {
            fprintf(stderr, "[Metal RT] Trace failed: %s\n",
                    [[cmdBuf.error localizedDescription] UTF8String]);
            return false;
        }

        // ---- readback ----
        memcpy(output_pixels, [ctx->outputBuffer contents], needed);
        return true;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_destroy
// ---------------------------------------------------------------------------
extern "C" void guava_metal_rt_destroy(GuavaMetalRTContext* ctx) {
    if (!ctx) return;
    @autoreleasepool {
        ctx->accel                = nil;
        ctx->vertexPositionBuffer = nil;
        ctx->triangleDataBuffer   = nil;
        ctx->textureAtlasBuffer   = nil;
        ctx->textureMetaBuffer    = nil;
        ctx->samplingTableBuffer  = nil;
        ctx->samplingTableMetaBuffer = nil;
        ctx->outputBuffer         = nil;
        ctx->paramsBuffer         = nil;
        ctx->pipeline             = nil;
        ctx->commandQueue         = nil;
        ctx->device               = nil;
        delete ctx;
    }
}
