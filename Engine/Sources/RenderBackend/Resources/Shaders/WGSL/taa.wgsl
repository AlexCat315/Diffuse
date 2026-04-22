struct TAAUniforms {
    blend_factor : f32,
    texel_size_x : f32,
    texel_size_y : f32,
    history_valid : f32,
};

@group(0) @binding(0) var taa_sampler : sampler;
@group(0) @binding(1) var current_texture : texture_2d<f32>;
@group(0) @binding(2) var history_texture : texture_2d<f32>;
@group(0) @binding(3) var<uniform> u : TAAUniforms;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
};

fn clip_aabb(color : vec3<f32>, min_color : vec3<f32>, max_color : vec3<f32>) -> vec3<f32> {
    let center = 0.5 * (max_color + min_color);
    let extents = 0.5 * (max_color - min_color);
    let offset = color - center;
    let ts = abs(extents) / max(abs(offset), vec3<f32>(0.0001));
    let t = min(1.0, min(ts.x, min(ts.y, ts.z)));
    return center + offset * t;
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
    let current = textureSample(current_texture, taa_sampler, in.uv).rgb;
    if (u.history_valid < 0.5) {
        return vec4<f32>(current, 1.0);
    }

    let history = textureSample(history_texture, taa_sampler, in.uv).rgb;
    let texel = vec2<f32>(u.texel_size_x, u.texel_size_y);

    var min_color = current;
    var max_color = current;
    for (var y : i32 = -1; y <= 1; y += 1) {
        for (var x : i32 = -1; x <= 1; x += 1) {
            let sample_uv = clamp(in.uv + vec2<f32>(f32(x), f32(y)) * texel, vec2<f32>(0.0), vec2<f32>(1.0));
            let sample_color = textureSample(current_texture, taa_sampler, sample_uv).rgb;
            min_color = min(min_color, sample_color);
            max_color = max(max_color, sample_color);
        }
    }

    let clipped_history = clip_aabb(history, min_color, max_color);
    let blend = clamp(u.blend_factor, 0.0, 1.0);
    return vec4<f32>(mix(current, clipped_history, blend), 1.0);
}