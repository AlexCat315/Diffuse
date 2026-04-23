struct TonemapUniforms {
    exposure : f32,
    bloom_mix : f32,
    use_bloom : f32,
    output_srgb : f32,
};

@group(0) @binding(0) var tone_sampler : sampler;
@group(0) @binding(1) var hdr_texture : texture_2d<f32>;
@group(0) @binding(2) var bloom_texture : texture_2d<f32>;
@group(0) @binding(3) var<uniform> u : TonemapUniforms;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
};

fn aces_film(x : vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn linear_to_srgb(linear : vec3<f32>) -> vec3<f32> {
    let lo = linear * 12.92;
    let hi = 1.055 * pow(max(linear, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.4)) - vec3<f32>(0.055);
    return select(lo, hi, linear >= vec3<f32>(0.0031308));
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
    var hdr = textureSample(hdr_texture, tone_sampler, in.uv).rgb * max(u.exposure, 0.001);
    if (u.use_bloom > 0.5) {
        hdr += textureSample(bloom_texture, tone_sampler, in.uv).rgb * max(u.bloom_mix, 0.0);
    }

    var ldr = aces_film(hdr);
    if (u.output_srgb > 0.5) {
        ldr = linear_to_srgb(ldr);
    }
    return vec4<f32>(ldr, 1.0);
}