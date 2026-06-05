struct Uniforms {
    mvp        : mat4x4<f32>,
    model      : mat4x4<f32>,
    color_tint : vec4<f32>,
};

struct SceneLight {
    position_and_type       : vec4<f32>,
    direction_and_range     : vec4<f32>,
    color_and_intensity     : vec4<f32>,
    spot_angles_and_padding : vec4<f32>,
};

struct SceneLights {
    ambient_color_intensity : vec4<f32>,
    exposure_light_count    : vec4<f32>,
    lights                  : array<SceneLight, 8>,
};

struct ShadowUniforms {
    light_view_projection0 : mat4x4<f32>,
    light_view_projection1 : mat4x4<f32>,
    light_view_projection2 : mat4x4<f32>,
    light_view_projection3 : mat4x4<f32>,
    params0 : vec4<f32>,
    params1 : vec4<f32>,
    params2 : vec4<f32>,
    params3 : vec4<f32>,
    atlas_params : vec4<f32>,
    cascade_splits : vec4<f32>,
    camera_position_and_padding : vec4<f32>,
    camera_forward_and_padding : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(2) var base_color_sampler : sampler;
@group(0) @binding(3) var base_color_texture : texture_2d<f32>;
@group(0) @binding(4) var<uniform> scene_lights : SceneLights;
@group(0) @binding(5) var<uniform> shadow : ShadowUniforms;
@group(0) @binding(6) var shadow_sampler : sampler;
@group(0) @binding(7) var shadow_texture : texture_2d<f32>;
@group(0) @binding(8) var<storage, read> joint_palette : array<mat4x4<f32>>;
@group(0) @binding(9) var normal_map_texture : texture_2d<f32>;
@group(0) @binding(10) var mr_texture : texture_2d<f32>;
@group(0) @binding(11) var ibl_env : texture_2d<f32>;

struct VsIn {
    @location(0) pos            : vec3<f32>,
    @location(1) normal         : vec3<f32>,
    @location(2) color          : vec3<f32>,
    @location(3) uv             : vec2<f32>,
    @location(4) tangent        : vec4<f32>,
    @location(5) material_index : f32,
    @location(6) joints         : vec4<f32>,
    @location(7) weights        : vec4<f32>,
};

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) color          : vec3<f32>,
    @location(1) normal         : vec3<f32>,
    @location(2) uv             : vec2<f32>,
    @location(3) material_index : f32,
    @location(4) world_pos      : vec3<f32>,
    @location(5) tangent        : vec3<f32>,
    @location(6) bitangent      : vec3<f32>,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;

    let skin = skin_matrix(in.joints, in.weights);
    let local = skin * vec4<f32>(in.pos, 1.0);
    let world = u.model * local;
    let normal   = u.model * (skin * vec4<f32>(in.normal, 0.0));
    let tangent  = u.model * (skin * vec4<f32>(in.tangent.xyz, 0.0));

    let N = safe_normalize(normal.xyz);
    let T = safe_normalize(tangent.xyz);
    let B = cross(N, T) * in.tangent.w;

    out.position   = u.mvp * local;
    out.color      = in.color;
    out.normal     = N;
    out.uv         = in.uv;
    out.material_index = in.material_index;
    out.world_pos  = world.xyz;
    out.tangent    = T;
    out.bitangent  = B;
    return out;
}

fn skin_matrix(joints : vec4<f32>, weights : vec4<f32>) -> mat4x4<f32> {
    let total_weight = weights.x + weights.y + weights.z + weights.w;
    if total_weight > 0.0001 && arrayLength(&joint_palette) > 0u {
        let j = vec4<u32>(u32(joints.x), u32(joints.y), u32(joints.z), u32(joints.w));
        let count = arrayLength(&joint_palette);
        return joint_matrix(j.x, count) * weights.x
            + joint_matrix(j.y, count) * weights.y
            + joint_matrix(j.z, count) * weights.z
            + joint_matrix(j.w, count) * weights.w;
    }
    return mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
}

fn joint_matrix(index : u32, count : u32) -> mat4x4<f32> {
    if index < count {
        return joint_palette[index];
    }
    return mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
}

fn safe_normalize(v : vec3<f32>) -> vec3<f32> {
    let len2 = dot(v, v);
    if len2 <= 0.000001 {
        return vec3<f32>(0.0, 1.0, 0.0);
    }
    return v * inverseSqrt(len2);
}

fn light_contribution(light : SceneLight, normal : vec3<f32>, world_pos : vec3<f32>, shadow_base_slot : i32, shadow_cascade_count : i32) -> vec3<f32> {
    let light_type = light.position_and_type.w;
    let light_color = light.color_and_intensity.rgb;
    let intensity = light.color_and_intensity.a;

    var to_light = vec3<f32>(0.0, 1.0, 0.0);
    var attenuation = 1.0;

    if light_type < 0.5 {
        to_light = safe_normalize(-light.direction_and_range.xyz);
    } else {
        let offset = light.position_and_type.xyz - world_pos;
        let distance = length(offset);
        to_light = safe_normalize(offset);
        let range = max(light.direction_and_range.w, 0.001);
        let normalized_distance = clamp(distance / range, 0.0, 1.0);
        attenuation = pow(1.0 - normalized_distance, 2.0);

        if light_type >= 1.5 {
            let light_to_surface = safe_normalize(world_pos - light.position_and_type.xyz);
            let cone = dot(safe_normalize(light.direction_and_range.xyz), light_to_surface);
            let inner_cos = cos(light.spot_angles_and_padding.x);
            let outer_cos = cos(light.spot_angles_and_padding.y);
            attenuation = attenuation * smoothstep(outer_cos, inner_cos, cone);
        }
    }

    let lambert = max(dot(normal, to_light), 0.0);
    var visibility = 1.0;
    if light_type < 0.5 && shadow_base_slot >= 0 {
        visibility = shadow_visibility(world_pos, u32(shadow_base_slot), u32(max(shadow_cascade_count, 1)));
    }
    return light_color * intensity * attenuation * lambert * visibility;
}

fn shadow_visibility(world_pos : vec3<f32>, base_slot : u32, cascade_count : u32) -> f32 {
    let slot = base_slot + shadow_cascade_index(world_pos, cascade_count);
    if shadow.atlas_params.x < 0.5 || f32(slot) >= shadow.atlas_params.y {
        return 1.0;
    }

    let clip = shadow_matrix(slot) * vec4<f32>(world_pos, 1.0);
    let inv_w = 1.0 / max(abs(clip.w), 0.00001);
    let ndc = clip.xyz * inv_w;
    let local_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if local_uv.x < 0.0 || local_uv.x > 1.0 || local_uv.y < 0.0 || local_uv.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0 {
        return 1.0;
    }

    let params = shadow_params(slot);
    let tile_scale = shadow.atlas_params.z / max(shadow.atlas_params.w, 1.0);
    let uv = params.zw + local_uv * tile_scale;
    let current_depth = ndc.z;
    let bias = params.x;
    let strength = clamp(params.y, 0.0, 1.0);
    let texel = 1.0 / max(shadow.atlas_params.w, 1.0);
    var lit = shadow_depth_lit(uv, current_depth, bias);
    lit = lit + shadow_depth_lit(uv + vec2<f32>(texel, 0.0), current_depth, bias);
    lit = lit + shadow_depth_lit(uv + vec2<f32>(-texel, 0.0), current_depth, bias);
    lit = lit + shadow_depth_lit(uv + vec2<f32>(0.0, texel), current_depth, bias);
    lit = lit + shadow_depth_lit(uv + vec2<f32>(0.0, -texel), current_depth, bias);
    lit = lit / 5.0;
    return 1.0 - strength * (1.0 - lit);
}

fn shadow_cascade_index(world_pos : vec3<f32>, cascade_count : u32) -> u32 {
    if cascade_count <= 1u {
        return 0u;
    }
    let view_depth = dot(world_pos - shadow.camera_position_and_padding.xyz, shadow.camera_forward_and_padding.xyz);
    if view_depth <= shadow.cascade_splits.x {
        return 0u;
    }
    if cascade_count <= 2u || view_depth <= shadow.cascade_splits.y {
        return 1u;
    }
    if cascade_count <= 3u || view_depth <= shadow.cascade_splits.z {
        return 2u;
    }
    return 3u;
}

fn shadow_depth_lit(uv : vec2<f32>, current_depth : f32, bias : f32) -> f32 {
    let occluder_depth = textureSample(shadow_texture, shadow_sampler, uv).r;
    if current_depth - bias > occluder_depth {
        return 0.0;
    }
    return 1.0;
}

fn shadow_matrix(slot : u32) -> mat4x4<f32> {
    if slot == 1u {
        return shadow.light_view_projection1;
    }
    if slot == 2u {
        return shadow.light_view_projection2;
    }
    if slot == 3u {
        return shadow.light_view_projection3;
    }
    return shadow.light_view_projection0;
}

fn shadow_params(slot : u32) -> vec4<f32> {
    if slot == 1u {
        return shadow.params1;
    }
    if slot == 2u {
        return shadow.params2;
    }
    if slot == 3u {
        return shadow.params3;
    }
    return shadow.params0;
}

fn scene_lighting(normal : vec3<f32>, world_pos : vec3<f32>) -> vec3<f32> {
    var lighting = scene_lights.ambient_color_intensity.rgb * scene_lights.ambient_color_intensity.a;
    let count = min(u32(scene_lights.exposure_light_count.y), 8u);
    for (var i = 0u; i < 8u; i = i + 1u) {
        if i >= count {
            continue;
        }
        let shadow_base_slot = i32(scene_lights.lights[i].spot_angles_and_padding.z) - 1;
        let shadow_cascade_count = i32(max(scene_lights.lights[i].spot_angles_and_padding.w, 1.0));
        lighting = lighting + light_contribution(
            scene_lights.lights[i],
            normal,
            world_pos,
            shadow_base_slot,
            shadow_cascade_count
        );
    }
    return max(lighting, vec3<f32>(0.0));
}

// Image-based lighting from the baked studio environment (a mipmapped equirect
// HDR; mip level stands in for roughness prefilter).
const IBL_MAX_LOD : f32 = 5.0;

fn equirect_uv(d : vec3<f32>) -> vec2<f32> {
    let phi = atan2(d.z, d.x);
    let theta = acos(clamp(d.y, -1.0, 1.0));
    return vec2<f32>(phi * 0.15915494 + 0.5, theta * 0.31830989); // 1/2π, 1/π
}

fn ibl_sample(dir : vec3<f32>, lod : f32) -> vec3<f32> {
    return textureSampleLevel(ibl_env, base_color_sampler, equirect_uv(dir), lod).rgb;
}

// Karis' analytic environment BRDF (avoids needing a BRDF integration LUT).
fn env_brdf_approx(NdotV : f32, roughness : f32) -> vec2<f32> {
    let c0 = vec4<f32>(-1.0, -0.0275, -0.572, 0.022);
    let c1 = vec4<f32>(1.0, 0.0425, 1.04, -0.04);
    let r = roughness * c0 + c1;
    let a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
    return vec2<f32>(-1.04, 1.04) * a004 + vec2<f32>(r.z, r.w);
}

// ACES-ish filmic tonemap so bright lights (the key light is intensity 3) roll
// off instead of clamping to white.
fn tonemap_aces(x : vec3<f32>) -> vec3<f32> {
    let a = 2.51; let b = 0.03; let c = 2.43; let d = 0.59; let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

const PI = 3.14159265359;

fn d_ggx(NdotH : f32, rough : f32) -> f32 {
    let a = rough * rough;
    let a2 = a * a;
    let denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(PI * denom * denom, 1e-6);
}

fn g_smith(NdotV : f32, NdotL : f32, rough : f32) -> f32 {
    let r = rough + 1.0;
    let k = (r * r) / 8.0;
    let gv = NdotV / (NdotV * (1.0 - k) + k);
    let gl = NdotL / (NdotL * (1.0 - k) + k);
    return gv * gl;
}

fn f_schlick(cos_theta : f32, F0 : vec3<f32>) -> vec3<f32> {
    return F0 + (vec3<f32>(1.0) - F0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

// Direct Cook-Torrance lighting (diffuse + GGX specular) over the scene lights.
// The specular term is what gives metal its sharp highlights and reveals the
// normal-mapped brushing/scratches — the previous shader had none.
fn direct_lighting(N : vec3<f32>, V : vec3<f32>, world_pos : vec3<f32>,
                   diffuse_albedo : vec3<f32>, F0 : vec3<f32>, roughness : f32) -> vec3<f32> {
    let NdotV = max(dot(N, V), 1e-4);
    var result = scene_lights.ambient_color_intensity.rgb
                 * scene_lights.ambient_color_intensity.a * diffuse_albedo;
    let count = min(u32(scene_lights.exposure_light_count.y), 8u);
    for (var i = 0u; i < 8u; i = i + 1u) {
        if i >= count { continue; }
        let light = scene_lights.lights[i];
        let light_type = light.position_and_type.w;
        var L = vec3<f32>(0.0, 1.0, 0.0);
        var attenuation = 1.0;
        if light_type < 0.5 {
            L = safe_normalize(-light.direction_and_range.xyz);
        } else {
            let offset = light.position_and_type.xyz - world_pos;
            let dist = length(offset);
            L = safe_normalize(offset);
            let range = max(light.direction_and_range.w, 0.001);
            attenuation = pow(1.0 - clamp(dist / range, 0.0, 1.0), 2.0);
        }
        let NdotL = max(dot(N, L), 0.0);
        if NdotL <= 0.0 { continue; }
        var visibility = 1.0;
        if light_type < 0.5 {
            let slot = i32(light.spot_angles_and_padding.z) - 1;
            let casc = i32(max(light.spot_angles_and_padding.w, 1.0));
            if slot >= 0 {
                visibility = shadow_visibility(world_pos, u32(slot), u32(max(casc, 1)));
            }
        }
        let radiance = light.color_and_intensity.rgb * light.color_and_intensity.a * attenuation * visibility;
        let H = safe_normalize(V + L);
        let NdotH = max(dot(N, H), 0.0);
        let HdotV = max(dot(H, V), 0.0);
        let D = d_ggx(NdotH, roughness);
        let G = g_smith(NdotV, NdotL, roughness);
        let F = f_schlick(HdotV, F0);
        let specular = (D * G * F) / max(4.0 * NdotV * NdotL, 1e-4);
        let kd = vec3<f32>(1.0) - F; // energy left for diffuse (metals → ~0)
        result = result + (kd * diffuse_albedo / PI + specular) * radiance * NdotL;
    }
    return result;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let texel = textureSample(base_color_texture, base_color_sampler, in.uv);
    // Base-color textures are authored in sRGB; linearize before lighting so
    // the whole shading math is done in linear light (the previous shader lit
    // sRGB values directly, which over-brightened and washed everything out).
    let albedo = pow(in.color * texel.rgb * u.color_tint.rgb, vec3<f32>(2.2));

    // ORM/ARM map: occlusion (R), roughness (G), metallic (B). Defaults to a
    // non-metal fallback (metallic = 0) for meshes without one.
    let arm       = textureSample(mr_texture, base_color_sampler, in.uv);
    let ao        = arm.r;
    let roughness = clamp(arm.g, 0.05, 1.0);
    let metallic  = arm.b;

    let nm_sample = textureSample(normal_map_texture, base_color_sampler, in.uv).rgb;
    let tangent_n = nm_sample * 2.0 - 1.0;
    let N = safe_normalize(in.normal);
    let T = safe_normalize(in.tangent);
    let B = safe_normalize(in.bitangent);
    let normal = safe_normalize(mat3x3<f32>(T, B, N) * tangent_n);

    let cam = shadow.camera_position_and_padding.xyz;
    let V = safe_normalize(cam - in.world_pos);
    // Reflect the environment with the SMOOTH geometric normal — using the
    // detail-normal here turns the high-frequency normal map into reflection
    // noise. The detail normal is still used for direct lighting below.
    let R = reflect(-V, N);
    let NdotV = max(dot(normal, V), 1e-3);
    let exposure = scene_lights.exposure_light_count.x;

    // Metal reflectance vs dielectric: metals take their colour from F0 and have
    // no diffuse; dielectrics keep a 4% specular and a diffuse albedo.
    let F0 = mix(vec3<f32>(0.04), albedo, metallic);
    let diffuse_albedo = albedo * (1.0 - metallic);
    let fresnel = F0 + (max(vec3<f32>(1.0 - roughness), F0) - F0) * pow(1.0 - NdotV, 5.0);

    // Direct Cook-Torrance lighting (diffuse + sharp GGX specular highlights).
    let direct = direct_lighting(normal, V, in.world_pos, diffuse_albedo, F0, roughness) * exposure;

    // Prefiltered IBL: specular reflection of the studio environment (mip level
    // = roughness) weighted by the analytic environment BRDF, plus an irradiance
    // diffuse fill from the most-blurred mip.
    let env_brdf = env_brdf_approx(NdotV, roughness);
    let env_spec = ibl_sample(R, roughness * IBL_MAX_LOD) * (F0 * env_brdf.x + env_brdf.y);
    let env_diff = ibl_sample(normal, IBL_MAX_LOD) * diffuse_albedo;
    let ambient = (env_spec + env_diff) * ao;

    var color = direct + ambient;
    color = tonemap_aces(color);
    color = pow(color, vec3<f32>(1.0 / 2.2)); // linear → sRGB for the viewport target
    return vec4<f32>(color, texel.a * u.color_tint.a);
}
