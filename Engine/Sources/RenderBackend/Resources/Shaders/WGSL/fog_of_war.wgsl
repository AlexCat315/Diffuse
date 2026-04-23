@group(0) @binding(0) var war_sampler : sampler;
@group(0) @binding(1) var source_texture : texture_2d<f32>;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index : u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    var uvs = array<vec2<f32>, 3>(vec2<f32>(0.0, 1.0), vec2<f32>(2.0, 1.0), vec2<f32>(0.0, -1.0));
    var out : VsOut;
    out.position = vec4<f32>(positions[vertex_index], 0.0, 1.0);
    out.uv = uvs[vertex_index];
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let base = textureSample(source_texture, war_sampler, in.uv).rgb;
    let center = distance(in.uv, vec2<f32>(0.5, 0.5));
    let fog = smoothstep(0.35, 0.8, center);
    return vec4<f32>(mix(base, base * 0.22, fog), 1.0);
}