@group(0) @binding(0) var fxaa_sampler : sampler;
@group(0) @binding(1) var color_texture : texture_2d<f32>;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
};

fn luminance(color : vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.299, 0.587, 0.114));
}

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

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let texel = 1.0 / vec2<f32>(vec2<u32>(textureDimensions(color_texture)));

    let rgb_m = textureSample(color_texture, fxaa_sampler, in.uv).rgb;
    let rgb_n = textureSample(color_texture, fxaa_sampler, in.uv + vec2<f32>(0.0, -texel.y)).rgb;
    let rgb_s = textureSample(color_texture, fxaa_sampler, in.uv + vec2<f32>(0.0, texel.y)).rgb;
    let rgb_w = textureSample(color_texture, fxaa_sampler, in.uv + vec2<f32>(-texel.x, 0.0)).rgb;
    let rgb_e = textureSample(color_texture, fxaa_sampler, in.uv + vec2<f32>(texel.x, 0.0)).rgb;

    let luma_m = luminance(rgb_m);
    let luma_n = luminance(rgb_n);
    let luma_s = luminance(rgb_s);
    let luma_w = luminance(rgb_w);
    let luma_e = luminance(rgb_e);

    let luma_min = min(luma_m, min(min(luma_n, luma_s), min(luma_w, luma_e)));
    let luma_max = max(luma_m, max(max(luma_n, luma_s), max(luma_w, luma_e)));
    let range = luma_max - luma_min;
    let threshold = max(0.0312, luma_max * 0.125);
    if (range < threshold) {
        return vec4<f32>(rgb_m, 1.0);
    }

    var dir = vec2<f32>(
        -((luma_n + luma_s) - 2.0 * luma_m),
        (luma_w + luma_e) - 2.0 * luma_m
    );
    let dir_reduce = max((luma_n + luma_s + luma_w + luma_e) * 0.25 * 0.0312, 0.0078125);
    let rcp_dir_min = 1.0 / (min(abs(dir.x), abs(dir.y)) + dir_reduce);
    dir = clamp(dir * rcp_dir_min, vec2<f32>(-8.0), vec2<f32>(8.0)) * texel;

    let rgb_a = 0.5 * (
        textureSample(color_texture, fxaa_sampler, in.uv + dir * (1.0 / 3.0 - 0.5)).rgb +
        textureSample(color_texture, fxaa_sampler, in.uv + dir * (2.0 / 3.0 - 0.5)).rgb
    );
    let rgb_b = rgb_a * 0.5 + 0.25 * (
        textureSample(color_texture, fxaa_sampler, in.uv - dir * 0.5).rgb +
        textureSample(color_texture, fxaa_sampler, in.uv + dir * 0.5).rgb
    );

    let luma_b = luminance(rgb_b);
    let result = select(rgb_b, rgb_a, luma_b < luma_min || luma_b > luma_max);
    return vec4<f32>(result, 1.0);
}