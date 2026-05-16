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
    @location(0) color : vec3<f32>,
    @location(1) normal : vec3<f32>,
    @location(2) uv : vec2<f32>,
    @location(3) material_index : f32,
    @location(4) world_pos : vec3<f32>,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    let world = u.model * vec4<f32>(in.pos, 1.0);
    out.position = u.mvp * vec4<f32>(in.pos, 1.0);
    out.color = in.color;
    out.normal = safe_normalize((u.model * vec4<f32>(in.normal, 0.0)).xyz);
    out.uv = in.uv;
    out.material_index = in.material_index;
    out.world_pos = world.xyz;
    return out;
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

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let normal = normalize(in.normal);
    let rim = pow(1.0 - max(normal.z, 0.0), 2.0);
    let texel = textureSample(base_color_texture, base_color_sampler, in.uv);
    let base = in.color * texel.rgb * u.color_tint.rgb;
    let lighting = scene_lighting(normal, in.world_pos);
    let exposure = scene_lights.exposure_light_count.x;
    let hdr = base * (lighting + rim * 0.18) * exposure;
    return vec4<f32>(hdr, texel.a * u.color_tint.a);
}
