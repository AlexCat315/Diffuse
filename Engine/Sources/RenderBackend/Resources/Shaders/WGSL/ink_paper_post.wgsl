struct StylizedStyle {
    toon_thresholds : vec4<f32>,
    toon_levels : vec4<f32>,
    ink_wash_color : vec4<f32>,
    params : vec4<f32>,
};

@group(0) @binding(0) var post_sampler : sampler;
@group(0) @binding(1) var color_texture : texture_2d<f32>;
@group(0) @binding(2) var<uniform> style : StylizedStyle;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index : u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0)
    );
    var uvs = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 1.0),
        vec2<f32>(2.0, 1.0),
        vec2<f32>(0.0, -1.0)
    );

    var out : VsOut;
    out.position = vec4<f32>(positions[vertex_index], 0.0, 1.0);
    out.uv = uvs[vertex_index];
    return out;
}

fn luminance(color : vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn paper_hash(uv : vec2<f32>) -> f32 {
    let p = vec2<f32>(dot(uv, vec2<f32>(127.1, 311.7)),
                      dot(uv, vec2<f32>(269.5, 183.3)));
    return fract(sin(p.x + p.y) * 43758.5453);
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let texel = 1.0 / vec2<f32>(vec2<u32>(textureDimensions(color_texture)));
    let center = textureSample(color_texture, post_sampler, in.uv).rgb;
    let north = textureSample(color_texture, post_sampler, in.uv + vec2<f32>(0.0, -texel.y)).rgb;
    let east = textureSample(color_texture, post_sampler, in.uv + vec2<f32>(texel.x, 0.0)).rgb;

    let contrast = abs(luminance(center) - luminance(north)) + abs(luminance(center) - luminance(east));
    let ink_edge = clamp(contrast * 1.8, 0.0, 0.22);
    let paper = (paper_hash(in.uv * vec2<f32>(320.0, 180.0)) - 0.5) * style.params.x * 1.8;
    let wash = mix(center, center * style.ink_wash_color.rgb, 0.08);
    let color = wash + vec3<f32>(paper) - vec3<f32>(ink_edge);
    return vec4<f32>(max(color, vec3<f32>(0.0)), 1.0);
}
