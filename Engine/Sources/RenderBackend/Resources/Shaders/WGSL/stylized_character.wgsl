struct Uniforms {
    mvp : mat4x4<f32>,
    model : mat4x4<f32>,
};

struct StylizedStyle {
    toon_thresholds : vec4<f32>,
    toon_levels : vec4<f32>,
    ink_wash_color : vec4<f32>,
    params : vec4<f32>,
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

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(1) var<uniform> style : StylizedStyle;
@group(0) @binding(2) var base_color_sampler : sampler;
@group(0) @binding(3) var base_color_texture : texture_2d<f32>;
@group(0) @binding(4) var<uniform> scene_lights : SceneLights;

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

fn toon_ramp(v : f32) -> f32 {
    if v < style.toon_thresholds.x {
        return style.toon_levels.x;
    }
    if v < style.toon_thresholds.y {
        return style.toon_levels.y;
    }
    return style.toon_levels.z;
}

fn paper_grain(uv : vec2<f32>) -> f32 {
    let p = fract(vec2<f32>(dot(uv, vec2<f32>(127.1, 311.7)),
                            dot(uv, vec2<f32>(269.5, 183.3))));
    return fract(sin(p.x + p.y) * 43758.5453);
}

fn scene_lambert(normal : vec3<f32>, world_pos : vec3<f32>) -> f32 {
    var lighting = scene_lights.ambient_color_intensity.a;
    let count = min(u32(scene_lights.exposure_light_count.y), 8u);
    for (var i = 0u; i < 8u; i = i + 1u) {
        if i >= count {
            continue;
        }

        let light = scene_lights.lights[i];
        let light_type = light.position_and_type.w;
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

        let weighted = max(dot(normal, to_light), 0.0) * light.color_and_intensity.a * attenuation;
        lighting = lighting + weighted;
    }
    return clamp(lighting, 0.0, 1.5);
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let normal = normalize(in.normal);
    let lambert = scene_lambert(normal, in.world_pos);
    let ramp = toon_ramp(lambert);
    let rim = smoothstep(0.38, 0.95, 1.0 - max(normal.z, 0.0));
    let ink_wash = style.ink_wash_color.rgb;
    let material_bias = fract(in.material_index * 0.173) * style.params.z;
    let grain = (paper_grain(in.uv * 83.0) - 0.5) * style.params.x;
    let texel = textureSample(base_color_texture, base_color_sampler, in.uv).rgb;
    let base = mix(ink_wash, in.color * texel, 0.78);
    let shaded = base * (0.28 + ramp * 0.92 + rim * style.params.y + material_bias + grain);
    return vec4<f32>(shaded, 1.0);
}
