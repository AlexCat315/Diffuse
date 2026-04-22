struct BloomUniforms {
    threshold : f32,
    intensity : f32,
    texel_size_x : f32,
    texel_size_y : f32,
};

@group(0) @binding(0) var bloom_sampler : sampler;
@group(0) @binding(1) var hdr_texture : texture_2d<f32>;
@group(0) @binding(2) var<uniform> u : BloomUniforms;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
};

fn luminance(color : vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
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
    let texel = vec2<f32>(u.texel_size_x, u.texel_size_y);
    let offsets = array<vec2<f32>, 9>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(0.0, -1.0), vec2<f32>(1.0, -1.0),
        vec2<f32>(-1.0,  0.0), vec2<f32>(0.0,  0.0), vec2<f32>(1.0,  0.0),
        vec2<f32>(-1.0,  1.0), vec2<f32>(0.0,  1.0), vec2<f32>(1.0,  1.0)
    );
    let weights = array<f32, 9>(1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0);

    var bloom = vec3<f32>(0.0);
    var total = 0.0;
    for (var i : u32 = 0u; i < 9u; i += 1u) {
        let sample_uv = in.uv + offsets[i] * texel * 2.0;
        let sample_color = textureSample(hdr_texture, bloom_sampler, sample_uv).rgb;
        let bright = max(luminance(sample_color) - u.threshold, 0.0);
        bloom += sample_color * bright * weights[i];
        total += weights[i];
    }

    bloom = bloom / max(total, 0.0001) * max(u.intensity, 0.0);
    return vec4<f32>(bloom, 1.0);
}