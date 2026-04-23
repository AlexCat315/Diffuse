struct SSAOUniforms {
    projection : mat4x4<f32>,
    inv_projection : mat4x4<f32>,
    resolution_radius : vec4<f32>,
    tuning : vec4<f32>,
};

@group(0) @binding(0) var ssao_sampler : sampler;
@group(0) @binding(1) var scene_texture : texture_2d<f32>;
@group(0) @binding(2) var depth_texture : texture_depth_2d;
@group(0) @binding(3) var<uniform> u : SSAOUniforms;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
};

fn get_view_pos(uv : vec2<f32>, depth : f32) -> vec3<f32> {
    let clip = vec4<f32>(uv * 2.0 - 1.0, depth, 1.0);
    let view = u.inv_projection * clip;
    return view.xyz / max(view.w, 0.00001);
}

fn reconstruct_normal(uv : vec2<f32>, view_pos : vec3<f32>) -> vec3<f32> {
    let texel = 1.0 / u.resolution_radius.xy;
    let uv_x = clamp(uv + vec2<f32>(texel.x, 0.0), vec2<f32>(0.0), vec2<f32>(1.0));
    let uv_y = clamp(uv + vec2<f32>(0.0, texel.y), vec2<f32>(0.0), vec2<f32>(1.0));
    let view_x = get_view_pos(uv_x, textureSample(depth_texture, ssao_sampler, uv_x));
    let view_y = get_view_pos(uv_y, textureSample(depth_texture, ssao_sampler, uv_y));
    return normalize(cross(view_x - view_pos, view_y - view_pos));
}

fn sample_kernel(index : u32) -> vec3<f32> {
    var samples = array<vec3<f32>, 8>(
        vec3<f32>(0.188, -0.126, 0.207),
        vec3<f32>(-0.241, 0.091, 0.356),
        vec3<f32>(0.096, 0.277, 0.441),
        vec3<f32>(-0.322, -0.251, 0.523),
        vec3<f32>(0.509, 0.114, 0.602),
        vec3<f32>(-0.085, 0.523, 0.644),
        vec3<f32>(0.387, -0.482, 0.713),
        vec3<f32>(-0.613, 0.204, 0.782)
    );
    return samples[index];
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
    let depth = textureSample(depth_texture, ssao_sampler, in.uv);
    let scene = textureSample(scene_texture, ssao_sampler, in.uv).rgb;
    if (depth >= 0.9999) {
        return vec4<f32>(scene, 1.0);
    }

    let view_pos = get_view_pos(in.uv, depth);
    let normal = reconstruct_normal(in.uv, view_pos);
    let texel = 1.0 / u.resolution;
    var occlusion = 0.0;

    for (var i : u32 = 0u; i < 8u; i += 1u) {
        let sample_dir = normalize(sample_kernel(i));
        let hemisphere = select(-sample_dir, sample_dir, dot(sample_dir, normal) >= 0.0);
        let sample_pos = view_pos + hemisphere * u.resolution_radius.z;
        let projected = u.projection * vec4<f32>(sample_pos, 1.0);
        let sample_uv = projected.xy / max(projected.w, 0.00001) * 0.5 + 0.5;
        if (any(sample_uv < vec2<f32>(0.0)) || any(sample_uv > vec2<f32>(1.0))) {
            continue;
        }

        let sample_depth = textureSample(depth_texture, ssao_sampler, sample_uv);
        let sample_view = get_view_pos(sample_uv, sample_depth);
        let range_check = smoothstep(0.0, 1.0, u.resolution_radius.z / (abs(view_pos.z - sample_view.z) + 0.001));
        if (sample_view.z >= sample_pos.z + u.tuning.x) {
            occlusion += range_check;
        }
    }

    var ao = 1.0 - occlusion / 8.0;
    ao = pow(clamp(ao, 0.0, 1.0), max(u.tuning.z, 0.001));
    let shaded = scene * mix(1.0, ao, clamp(u.tuning.y, 0.0, 1.0));
    return vec4<f32>(shaded, 1.0);
}