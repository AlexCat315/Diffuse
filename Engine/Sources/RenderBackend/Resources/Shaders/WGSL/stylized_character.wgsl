struct Uniforms {
    mvp : mat4x4<f32>,
};

struct StylizedStyle {
    toon_thresholds : vec4<f32>,
    toon_levels : vec4<f32>,
    ink_wash_color : vec4<f32>,
    params : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(1) var<uniform> style : StylizedStyle;
@group(0) @binding(2) var base_color_sampler : sampler;
@group(0) @binding(3) var base_color_texture : texture_2d<f32>;

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
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    out.position = u.mvp * vec4<f32>(in.pos, 1.0);
    out.color = in.color;
    out.normal = in.normal;
    out.uv = in.uv;
    out.material_index = in.material_index;
    return out;
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

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let light_dir = normalize(vec3<f32>(0.35, 0.82, 0.45));
    let normal = normalize(in.normal);
    let lambert = max(dot(normal, light_dir), 0.0);
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
