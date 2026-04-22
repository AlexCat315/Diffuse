struct SSRUniforms {
    projection : mat4x4<f32>,
    inv_projection : mat4x4<f32>,
    resolution_intensity : vec4<f32>,
    tracing : vec4<f32>,
};

@group(0) @binding(0) var ssr_sampler : sampler;
@group(0) @binding(1) var scene_texture : texture_2d<f32>;
@group(0) @binding(2) var depth_texture : texture_depth_2d;
@group(0) @binding(3) var<uniform> u : SSRUniforms;

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
    let texel = 1.0 / u.resolution;
    let uv_x = clamp(uv + vec2<f32>(texel.x, 0.0), vec2<f32>(0.0), vec2<f32>(1.0));
    let uv_y = clamp(uv + vec2<f32>(0.0, texel.y), vec2<f32>(0.0), vec2<f32>(1.0));
    let view_x = get_view_pos(uv_x, textureSample(depth_texture, ssr_sampler, uv_x));
    let view_y = get_view_pos(uv_y, textureSample(depth_texture, ssr_sampler, uv_y));
    return normalize(cross(view_x - view_pos, view_y - view_pos));
}

fn project_screen(view_pos : vec3<f32>) -> vec2<f32> {
    let clip = u.projection * vec4<f32>(view_pos, 1.0);
    let ndc = clip.xyz / max(clip.w, 0.00001);
    return ndc.xy * 0.5 + 0.5;
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
    let depth = textureSample(depth_texture, ssr_sampler, in.uv);
    if (depth >= 0.9999) {
        return vec4<f32>(textureSample(scene_texture, ssr_sampler, in.uv).rgb, 1.0);
    }

    let view_pos = get_view_pos(in.uv, depth);
    let normal = reconstruct_normal(in.uv, view_pos);
    let view_dir = normalize(-view_pos);
    let reflect_dir = reflect(-view_dir, normal);
    if (reflect_dir.z > 0.0) {
        return vec4<f32>(textureSample(scene_texture, ssr_sampler, in.uv).rgb, 1.0);
    }

    let max_steps = i32(max(u.tracing.y, 8.0));
    let step_size = u.tracing.x / max(u.tracing.y, 1.0);
    var hit_uv = in.uv;
    var hit = false;

    for (var i : i32 = 1; i <= max_steps; i += 1) {
        let sample_pos = view_pos + reflect_dir * step_size * f32(i);
        let screen_uv = project_screen(sample_pos);
        if (any(screen_uv < vec2<f32>(0.0)) || any(screen_uv > vec2<f32>(1.0))) {
            break;
        }

        let sample_depth = textureSample(depth_texture, ssr_sampler, screen_uv);
        let surface_pos = get_view_pos(screen_uv, sample_depth);
        if (surface_pos.z >= sample_pos.z && surface_pos.z - sample_pos.z < u.tracing.z) {
            hit_uv = screen_uv;
            hit = true;
            break;
        }
    }

    let scene = textureSample(scene_texture, ssr_sampler, in.uv).rgb;
    if (!hit) {
        return vec4<f32>(scene, 1.0);
    }

    let reflection = textureSample(scene_texture, ssr_sampler, hit_uv).rgb;
    let edge_fade = u.tracing.w;
    let fade_x = smoothstep(0.0, edge_fade, hit_uv.x) * smoothstep(0.0, edge_fade, 1.0 - hit_uv.x);
    let fade_y = smoothstep(0.0, edge_fade, hit_uv.y) * smoothstep(0.0, edge_fade, 1.0 - hit_uv.y);
    let reflection_mix = max(u.resolution_intensity.z, 0.0) * fade_x * fade_y;
    return vec4<f32>(mix(scene, scene + reflection * 0.5, reflection_mix), 1.0);
}